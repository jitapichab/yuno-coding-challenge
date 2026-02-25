package main

import (
	"bytes"
	"encoding/json"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"os"
	"strings"
	"sync/atomic"
	"testing"

	"github.com/prometheus/client_golang/prometheus"
	"github.com/prometheus/client_golang/prometheus/promhttp"

	"github.com/jitapichab/yuno-coding-challenge/mock-service/internal/config"
	"github.com/jitapichab/yuno-coding-challenge/mock-service/internal/handlers"
	"github.com/jitapichab/yuno-coding-challenge/mock-service/internal/metrics"
	"github.com/jitapichab/yuno-coding-challenge/mock-service/internal/middleware"
)

func setRequiredEnvVars(t *testing.T) {
	t.Helper()
	t.Setenv("DB_CONNECTION_STRING", "postgres://test:test@localhost:5432/testdb")
	t.Setenv("PROVIDER_API_KEY", "test-api-key-123")
	t.Setenv("ENCRYPTION_KEY", "test-encryption-key-456")
	t.Setenv("SERVICE_ENV", "test")
}

func TestConfigMissingEnvVars(t *testing.T) {
	// Ensure all required vars are unset.
	t.Setenv("DB_CONNECTION_STRING", "")
	t.Setenv("PROVIDER_API_KEY", "")
	t.Setenv("ENCRYPTION_KEY", "")
	t.Setenv("SERVICE_ENV", "")

	_, err := config.Load()
	if err == nil {
		t.Fatal("expected error when env vars are missing, got nil")
	}
	if !strings.Contains(err.Error(), "missing required environment variables") {
		t.Errorf("unexpected error message: %v", err)
	}
}

func TestConfigWithAllEnvVars(t *testing.T) {
	setRequiredEnvVars(t)

	cfg, err := config.Load()
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if cfg.DBConnectionString != "postgres://test:test@localhost:5432/testdb" {
		t.Errorf("unexpected DB_CONNECTION_STRING: %s", cfg.DBConnectionString)
	}
	if cfg.ServiceEnv != "test" {
		t.Errorf("unexpected SERVICE_ENV: %s", cfg.ServiceEnv)
	}
}

func TestHealthDuringStartup(t *testing.T) {
	ready := &atomic.Bool{}
	handler := handlers.NewHealthHandler(ready)

	req := httptest.NewRequest(http.MethodGet, "/health", nil)
	rr := httptest.NewRecorder()
	handler.ServeHTTP(rr, req)

	if rr.Code != http.StatusServiceUnavailable {
		t.Errorf("expected 503 during startup, got %d", rr.Code)
	}
}

func TestHealthAfterReady(t *testing.T) {
	ready := &atomic.Bool{}
	ready.Store(true)
	handler := handlers.NewHealthHandler(ready)

	req := httptest.NewRequest(http.MethodGet, "/health", nil)
	rr := httptest.NewRecorder()
	handler.ServeHTTP(rr, req)

	if rr.Code != http.StatusOK {
		t.Errorf("expected 200 after ready, got %d", rr.Code)
	}
}

func TestAuthorizeValidRequest(t *testing.T) {
	reg := prometheus.NewRegistry()
	m := metrics.New(reg)
	logger := slog.New(slog.NewJSONHandler(os.Stdout, nil))
	handler := handlers.NewAuthorizeHandler(m, logger)

	body := map[string]interface{}{
		"merchant_id": "merchant_abc",
		"amount":      100.50,
		"currency":    "USD",
		"card_token":  "tok_test123",
	}
	bodyBytes, _ := json.Marshal(body)

	req := httptest.NewRequest(http.MethodPost, "/v1/authorize", bytes.NewReader(bodyBytes))
	req.Header.Set("Content-Type", "application/json")
	rr := httptest.NewRecorder()

	handler.ServeHTTP(rr, req)

	if rr.Code != http.StatusOK {
		t.Errorf("expected 200, got %d. Body: %s", rr.Code, rr.Body.String())
	}

	var resp map[string]interface{}
	if err := json.NewDecoder(rr.Body).Decode(&resp); err != nil {
		t.Fatalf("failed to decode response: %v", err)
	}

	for _, field := range []string{"transaction_id", "status", "provider", "timestamp", "amount", "currency"} {
		if _, ok := resp[field]; !ok {
			t.Errorf("missing field %q in response", field)
		}
	}
}

func TestAuthorizeBadBody(t *testing.T) {
	reg := prometheus.NewRegistry()
	m := metrics.New(reg)
	logger := slog.New(slog.NewJSONHandler(os.Stdout, nil))
	handler := handlers.NewAuthorizeHandler(m, logger)

	req := httptest.NewRequest(http.MethodPost, "/v1/authorize", strings.NewReader("invalid json"))
	req.Header.Set("Content-Type", "application/json")
	rr := httptest.NewRecorder()

	handler.ServeHTTP(rr, req)

	if rr.Code != http.StatusBadRequest {
		t.Errorf("expected 400 for bad body, got %d", rr.Code)
	}
}

func TestAuthorizeMissingFields(t *testing.T) {
	reg := prometheus.NewRegistry()
	m := metrics.New(reg)
	logger := slog.New(slog.NewJSONHandler(os.Stdout, nil))
	handler := handlers.NewAuthorizeHandler(m, logger)

	body := map[string]interface{}{
		"merchant_id": "merchant_abc",
		// missing amount, currency, card_token
	}
	bodyBytes, _ := json.Marshal(body)

	req := httptest.NewRequest(http.MethodPost, "/v1/authorize", bytes.NewReader(bodyBytes))
	req.Header.Set("Content-Type", "application/json")
	rr := httptest.NewRecorder()

	handler.ServeHTTP(rr, req)

	if rr.Code != http.StatusBadRequest {
		t.Errorf("expected 400 for missing fields, got %d", rr.Code)
	}
}

func TestMetricsEndpoint(t *testing.T) {
	reg := prometheus.NewRegistry()
	m := metrics.New(reg)

	// Initialize each metric so they appear in the output.
	m.HTTPRequestsTotal.WithLabelValues("GET", "/test", "200").Inc()
	m.HTTPRequestDuration.WithLabelValues("GET", "/test").Observe(0.1)
	m.HTTPActiveRequests.WithLabelValues("GET", "/test").Inc()
	m.TransactionAuthTotal.WithLabelValues("approved", "stripe").Inc()
	m.TransactionAuthDuration.WithLabelValues("stripe").Observe(0.3)

	handler := promhttp.HandlerFor(reg, promhttp.HandlerOpts{})

	req := httptest.NewRequest(http.MethodGet, "/metrics", nil)
	rr := httptest.NewRecorder()
	handler.ServeHTTP(rr, req)

	if rr.Code != http.StatusOK {
		t.Errorf("expected 200 for /metrics, got %d", rr.Code)
	}

	contentType := rr.Header().Get("Content-Type")
	if !strings.Contains(contentType, "text/plain") {
		t.Errorf("expected text/plain content type, got %q", contentType)
	}

	body := rr.Body.String()
	expectedMetrics := []string{
		"http_requests_total",
		"http_request_duration_seconds",
		"http_active_requests",
		"transaction_authorizations_total",
		"transaction_authorization_duration_seconds",
	}
	for _, metric := range expectedMetrics {
		if !strings.Contains(body, metric) {
			t.Errorf("metrics output missing %q", metric)
		}
	}
}

func TestIntegrationMuxRouting(t *testing.T) {
	reg := prometheus.NewRegistry()
	m := metrics.New(reg)
	logger := slog.New(slog.NewJSONHandler(os.Stdout, nil))

	ready := &atomic.Bool{}
	ready.Store(true)

	healthHandler := handlers.NewHealthHandler(ready)
	authorizeHandler := handlers.NewAuthorizeHandler(m, logger)

	mux := http.NewServeMux()
	mux.Handle("/health", healthHandler)
	mux.Handle("/metrics", promhttp.HandlerFor(reg, promhttp.HandlerOpts{
		EnableOpenMetrics: false,
	}))
	mux.Handle("/v1/authorize", middleware.MetricsMiddleware(m)(authorizeHandler))

	// Test health.
	req := httptest.NewRequest(http.MethodGet, "/health", nil)
	rr := httptest.NewRecorder()
	mux.ServeHTTP(rr, req)
	if rr.Code != http.StatusOK {
		t.Errorf("health: expected 200, got %d", rr.Code)
	}

	// Test authorize.
	body := map[string]interface{}{
		"merchant_id": "m1",
		"amount":      10.0,
		"currency":    "USD",
		"card_token":  "tok_1",
	}
	bodyBytes, _ := json.Marshal(body)
	req = httptest.NewRequest(http.MethodPost, "/v1/authorize", bytes.NewReader(bodyBytes))
	rr = httptest.NewRecorder()
	mux.ServeHTTP(rr, req)
	if rr.Code != http.StatusOK {
		t.Errorf("authorize: expected 200, got %d. Body: %s", rr.Code, rr.Body.String())
	}

	// Test metrics.
	req = httptest.NewRequest(http.MethodGet, "/metrics", nil)
	rr = httptest.NewRecorder()
	mux.ServeHTTP(rr, req)
	if rr.Code != http.StatusOK {
		t.Errorf("metrics: expected 200, got %d", rr.Code)
	}
}
