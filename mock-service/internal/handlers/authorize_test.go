package handlers_test

import (
	"bytes"
	"encoding/json"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"os"
	"testing"

	"github.com/prometheus/client_golang/prometheus"

	"github.com/jitapichab/yuno-coding-challenge/mock-service/internal/handlers"
	"github.com/jitapichab/yuno-coding-challenge/mock-service/internal/metrics"
)

func newTestAuthorizeHandler(t *testing.T) http.Handler {
	t.Helper()
	reg := prometheus.NewRegistry()
	m := metrics.New(reg)
	logger := slog.New(slog.NewJSONHandler(os.Stdout, nil))
	return handlers.NewAuthorizeHandler(m, logger)
}

func TestAuthorizeHandler(t *testing.T) {
	tests := []struct {
		name           string
		method         string
		body           interface{}
		expectedStatus int
		checkResponse  func(t *testing.T, body map[string]interface{})
	}{
		{
			name:   "valid request returns 200 with valid JSON",
			method: http.MethodPost,
			body: map[string]interface{}{
				"merchant_id": "merchant_123",
				"amount":      99.99,
				"currency":    "USD",
				"card_token":  "tok_abc123",
			},
			expectedStatus: http.StatusOK,
			checkResponse: func(t *testing.T, body map[string]interface{}) {
				t.Helper()
				requiredFields := []string{"transaction_id", "status", "provider", "timestamp", "amount", "currency"}
				for _, field := range requiredFields {
					if _, ok := body[field]; !ok {
						t.Errorf("response missing required field %q", field)
					}
				}
				status, ok := body["status"].(string)
				if !ok {
					t.Fatal("status field is not a string")
				}
				validStatuses := map[string]bool{"approved": true, "declined": true, "error": true}
				if !validStatuses[status] {
					t.Errorf("unexpected status %q", status)
				}
				if body["currency"] != "USD" {
					t.Errorf("expected currency USD, got %v", body["currency"])
				}
				if body["amount"] != 99.99 {
					t.Errorf("expected amount 99.99, got %v", body["amount"])
				}
			},
		},
		{
			name:           "invalid JSON body returns 400",
			method:         http.MethodPost,
			body:           "not json",
			expectedStatus: http.StatusBadRequest,
			checkResponse: func(t *testing.T, body map[string]interface{}) {
				t.Helper()
				if _, ok := body["error"]; !ok {
					t.Error("expected error field in response")
				}
			},
		},
		{
			name:   "missing merchant_id returns 400",
			method: http.MethodPost,
			body: map[string]interface{}{
				"amount":     50.00,
				"currency":   "EUR",
				"card_token": "tok_xyz",
			},
			expectedStatus: http.StatusBadRequest,
			checkResponse: func(t *testing.T, body map[string]interface{}) {
				t.Helper()
				errMsg, ok := body["error"].(string)
				if !ok {
					t.Fatal("expected error to be a string")
				}
				if errMsg == "" {
					t.Error("expected non-empty error message")
				}
			},
		},
		{
			name:   "missing amount returns 400",
			method: http.MethodPost,
			body: map[string]interface{}{
				"merchant_id": "merchant_123",
				"currency":    "USD",
				"card_token":  "tok_abc",
			},
			expectedStatus: http.StatusBadRequest,
			checkResponse: func(t *testing.T, body map[string]interface{}) {
				t.Helper()
				if _, ok := body["error"]; !ok {
					t.Error("expected error field in response")
				}
			},
		},
		{
			name:   "missing currency returns 400",
			method: http.MethodPost,
			body: map[string]interface{}{
				"merchant_id": "merchant_123",
				"amount":      25.00,
				"card_token":  "tok_abc",
			},
			expectedStatus: http.StatusBadRequest,
			checkResponse: func(t *testing.T, body map[string]interface{}) {
				t.Helper()
				if _, ok := body["error"]; !ok {
					t.Error("expected error field in response")
				}
			},
		},
		{
			name:   "missing card_token returns 400",
			method: http.MethodPost,
			body: map[string]interface{}{
				"merchant_id": "merchant_123",
				"amount":      25.00,
				"currency":    "USD",
			},
			expectedStatus: http.StatusBadRequest,
			checkResponse: func(t *testing.T, body map[string]interface{}) {
				t.Helper()
				if _, ok := body["error"]; !ok {
					t.Error("expected error field in response")
				}
			},
		},
		{
			name:   "all fields missing returns 400",
			method: http.MethodPost,
			body: map[string]interface{}{},
			expectedStatus: http.StatusBadRequest,
			checkResponse: func(t *testing.T, body map[string]interface{}) {
				t.Helper()
				if _, ok := body["error"]; !ok {
					t.Error("expected error field in response")
				}
			},
		},
	}

	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			handler := newTestAuthorizeHandler(t)

			var bodyBytes []byte
			switch v := tc.body.(type) {
			case string:
				bodyBytes = []byte(v)
			default:
				var err error
				bodyBytes, err = json.Marshal(v)
				if err != nil {
					t.Fatalf("failed to marshal body: %v", err)
				}
			}

			req := httptest.NewRequest(tc.method, "/v1/authorize", bytes.NewReader(bodyBytes))
			req.Header.Set("Content-Type", "application/json")
			rr := httptest.NewRecorder()

			handler.ServeHTTP(rr, req)

			if rr.Code != tc.expectedStatus {
				t.Errorf("expected status %d, got %d. Body: %s", tc.expectedStatus, rr.Code, rr.Body.String())
			}

			var respBody map[string]interface{}
			if err := json.NewDecoder(rr.Body).Decode(&respBody); err != nil {
				t.Fatalf("failed to decode response: %v. Raw: %s", err, rr.Body.String())
			}

			if tc.checkResponse != nil {
				tc.checkResponse(t, respBody)
			}
		})
	}
}
