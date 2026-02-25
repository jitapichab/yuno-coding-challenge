package handlers

import (
	"context"
	"crypto/rand"
	"encoding/json"
	"fmt"
	"log/slog"
	"math"
	"math/big"
	mrand "math/rand"
	"net/http"
	"strings"
	"time"

	"github.com/jitapichab/yuno-coding-challenge/mock-service/internal/metrics"
)

// AuthorizeRequest represents the incoming authorization request body.
type AuthorizeRequest struct {
	MerchantID string  `json:"merchant_id"`
	Amount     float64 `json:"amount"`
	Currency   string  `json:"currency"`
	CardToken  string  `json:"card_token"`
}

// AuthorizeResponse represents the authorization response body.
type AuthorizeResponse struct {
	TransactionID string  `json:"transaction_id"`
	Status        string  `json:"status"`
	Provider      string  `json:"provider"`
	Timestamp     string  `json:"timestamp"`
	Amount        float64 `json:"amount"`
	Currency      string  `json:"currency"`
}

// providers used in mock simulation.
var providers = []string{"stripe", "adyen", "worldpay", "checkout_com"}

// AuthorizeHandler serves the POST /v1/authorize endpoint.
type AuthorizeHandler struct {
	metrics  *metrics.Metrics
	logger   *slog.Logger
	semaphore chan struct{}
}

// NewAuthorizeHandler creates a new AuthorizeHandler.
func NewAuthorizeHandler(m *metrics.Metrics, logger *slog.Logger) *AuthorizeHandler {
	return &AuthorizeHandler{
		metrics:  m,
		logger:   logger,
		semaphore: make(chan struct{}, 1000),
	}
}

// ServeHTTP implements http.Handler.
func (h *AuthorizeHandler) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	// Bounded concurrency: try to acquire a slot.
	select {
	case h.semaphore <- struct{}{}:
		defer func() { <-h.semaphore }()
	default:
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(http.StatusServiceUnavailable)
		json.NewEncoder(w).Encode(map[string]string{
			"error": "service at capacity, please retry",
		})
		return
	}

	h.handleAuthorize(r.Context(), w, r)
}

func (h *AuthorizeHandler) handleAuthorize(ctx context.Context, w http.ResponseWriter, r *http.Request) {
	start := time.Now()

	// Only accept POST.
	if r.Method != http.MethodPost {
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(http.StatusMethodNotAllowed)
		json.NewEncoder(w).Encode(map[string]string{
			"error": "method not allowed",
		})
		return
	}

	// Limit request body to 1MB to prevent abuse.
	r.Body = http.MaxBytesReader(w, r.Body, 1<<20) // 1MB

	// Decode request body.
	var req AuthorizeRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(http.StatusBadRequest)
		json.NewEncoder(w).Encode(map[string]string{
			"error": "invalid request body",
		})
		return
	}

	// Validate required fields.
	var missingFields []string
	if req.MerchantID == "" {
		missingFields = append(missingFields, "merchant_id")
	}
	if req.Amount == 0 {
		missingFields = append(missingFields, "amount")
	}
	if req.Currency == "" {
		missingFields = append(missingFields, "currency")
	}
	if req.CardToken == "" {
		missingFields = append(missingFields, "card_token")
	}
	if len(missingFields) > 0 {
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(http.StatusBadRequest)
		json.NewEncoder(w).Encode(map[string]string{
			"error": "missing required fields: " + strings.Join(missingFields, ", "),
		})
		return
	}

	// Select a random provider.
	provider := providers[mrand.Intn(len(providers))]

	// Simulate processing latency: normal distribution mean=340ms, stddev=150ms, capped at 2000ms.
	latency := simulateLatency()

	select {
	case <-ctx.Done():
		return
	case <-time.After(latency):
	}

	// Determine transaction status: 90% approved, 8% declined, 2% error.
	status := determineStatus()

	transactionID := generateUUID()
	now := time.Now().UTC()

	resp := AuthorizeResponse{
		TransactionID: transactionID,
		Status:        status,
		Provider:      provider,
		Timestamp:     now.Format(time.RFC3339),
		Amount:        req.Amount,
		Currency:      req.Currency,
	}

	duration := time.Since(start)

	// Record metrics.
	h.metrics.TransactionAuthTotal.WithLabelValues(status, provider).Inc()
	h.metrics.TransactionAuthDuration.WithLabelValues(provider).Observe(duration.Seconds())

	// Structured audit log — card_token is masked to prevent secret leakage.
	h.logger.Info("authorization_request",
		"transaction_id", transactionID,
		"merchant_id", req.MerchantID,
		"amount", req.Amount,
		"currency", req.Currency,
		"card_token_suffix", maskToken(req.CardToken),
		"status", status,
		"provider", provider,
		"duration_ms", duration.Milliseconds(),
		"client_ip", clientIP(r),
	)

	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(http.StatusOK)
	json.NewEncoder(w).Encode(resp)
}

// simulateLatency returns a duration drawn from a normal distribution
// with mean=340ms and stddev=150ms, clamped to [10ms, 2000ms].
func simulateLatency() time.Duration {
	ms := mrand.NormFloat64()*150 + 340
	ms = math.Max(10, math.Min(2000, ms))
	return time.Duration(ms) * time.Millisecond
}

// determineStatus returns "approved", "declined", or "error" based on
// weighted random selection: 90% approved, 8% declined, 2% error.
func determineStatus() string {
	roll := mrand.Float64()
	switch {
	case roll < 0.90:
		return "approved"
	case roll < 0.98:
		return "declined"
	default:
		return "error"
	}
}

// generateUUID produces a random UUID v4 string.
func generateUUID() string {
	b := make([]byte, 16)
	_, err := rand.Read(b)
	if err != nil {
		// Fallback to math/rand if crypto/rand fails (extremely unlikely).
		n, _ := rand.Int(rand.Reader, big.NewInt(math.MaxInt64))
		return fmt.Sprintf("%016x-0000-4000-8000-%012x", n.Int64(), n.Int64())
	}
	b[6] = (b[6] & 0x0f) | 0x40 // version 4
	b[8] = (b[8] & 0x3f) | 0x80 // variant 10
	return fmt.Sprintf("%08x-%04x-%04x-%04x-%012x",
		b[0:4], b[4:6], b[6:8], b[8:10], b[10:16])
}

// maskToken returns the last 4 characters of a token, masking the rest.
// This prevents sensitive token data from appearing in logs.
func maskToken(token string) string {
	if len(token) <= 4 {
		return "****"
	}
	return "****" + token[len(token)-4:]
}

// clientIP extracts the client IP address from the request.
func clientIP(r *http.Request) string {
	if xff := r.Header.Get("X-Forwarded-For"); xff != "" {
		parts := strings.Split(xff, ",")
		return strings.TrimSpace(parts[0])
	}
	if xrip := r.Header.Get("X-Real-Ip"); xrip != "" {
		return xrip
	}
	return r.RemoteAddr
}
