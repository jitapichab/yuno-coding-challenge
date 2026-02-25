package handlers

import (
	"encoding/json"
	"net/http"
	"sync/atomic"
)

// HealthHandler serves the /health endpoint.
// It returns 200 when the service is ready, 503 otherwise.
type HealthHandler struct {
	ready *atomic.Bool
}

// NewHealthHandler creates a new HealthHandler with the given readiness flag.
func NewHealthHandler(ready *atomic.Bool) *HealthHandler {
	return &HealthHandler{ready: ready}
}

// ServeHTTP implements http.Handler.
func (h *HealthHandler) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Content-Type", "application/json")

	if !h.ready.Load() {
		w.WriteHeader(http.StatusServiceUnavailable)
		json.NewEncoder(w).Encode(map[string]string{
			"status": "unavailable",
		})
		return
	}

	w.WriteHeader(http.StatusOK)
	json.NewEncoder(w).Encode(map[string]string{
		"status": "healthy",
	})
}
