package handlers_test

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"sync/atomic"
	"testing"

	"github.com/jitapichab/yuno-coding-challenge/mock-service/internal/handlers"
)

func TestHealthHandler_NotReady(t *testing.T) {
	ready := &atomic.Bool{}
	// ready defaults to false

	handler := handlers.NewHealthHandler(ready)

	req := httptest.NewRequest(http.MethodGet, "/health", nil)
	rr := httptest.NewRecorder()

	handler.ServeHTTP(rr, req)

	if rr.Code != http.StatusServiceUnavailable {
		t.Errorf("expected status %d during startup, got %d", http.StatusServiceUnavailable, rr.Code)
	}

	var body map[string]string
	if err := json.NewDecoder(rr.Body).Decode(&body); err != nil {
		t.Fatalf("failed to decode response body: %v", err)
	}
	if body["status"] != "unavailable" {
		t.Errorf("expected status 'unavailable', got %q", body["status"])
	}
}

func TestHealthHandler_Ready(t *testing.T) {
	ready := &atomic.Bool{}
	ready.Store(true)

	handler := handlers.NewHealthHandler(ready)

	req := httptest.NewRequest(http.MethodGet, "/health", nil)
	rr := httptest.NewRecorder()

	handler.ServeHTTP(rr, req)

	if rr.Code != http.StatusOK {
		t.Errorf("expected status %d when ready, got %d", http.StatusOK, rr.Code)
	}

	var body map[string]string
	if err := json.NewDecoder(rr.Body).Decode(&body); err != nil {
		t.Fatalf("failed to decode response body: %v", err)
	}
	if body["status"] != "healthy" {
		t.Errorf("expected status 'healthy', got %q", body["status"])
	}
}
