package metrics

import (
	"github.com/prometheus/client_golang/prometheus"
	"github.com/prometheus/client_golang/prometheus/promauto"
)

// Metrics holds all Prometheus metric collectors for the service.
type Metrics struct {
	HTTPRequestsTotal        *prometheus.CounterVec
	HTTPRequestDuration      *prometheus.HistogramVec
	HTTPActiveRequests       *prometheus.GaugeVec
	TransactionAuthTotal     *prometheus.CounterVec
	TransactionAuthDuration  *prometheus.HistogramVec
}

// New creates and registers all Prometheus metrics.
func New(reg prometheus.Registerer) *Metrics {
	return &Metrics{
		HTTPRequestsTotal: promauto.With(reg).NewCounterVec(
			prometheus.CounterOpts{
				Name: "http_requests_total",
				Help: "Total number of HTTP requests processed.",
			},
			[]string{"method", "path", "status"},
		),
		HTTPRequestDuration: promauto.With(reg).NewHistogramVec(
			prometheus.HistogramOpts{
				Name:    "http_request_duration_seconds",
				Help:    "Duration of HTTP requests in seconds.",
				Buckets: []float64{0.05, 0.1, 0.25, 0.5, 0.75, 1, 2.5},
			},
			[]string{"method", "path"},
		),
		HTTPActiveRequests: promauto.With(reg).NewGaugeVec(
			prometheus.GaugeOpts{
				Name: "http_active_requests",
				Help: "Number of currently active HTTP requests.",
			},
			[]string{"method", "path"},
		),
		TransactionAuthTotal: promauto.With(reg).NewCounterVec(
			prometheus.CounterOpts{
				Name: "transaction_authorizations_total",
				Help: "Total number of transaction authorizations.",
			},
			[]string{"status", "provider"},
		),
		TransactionAuthDuration: promauto.With(reg).NewHistogramVec(
			prometheus.HistogramOpts{
				Name:    "transaction_authorization_duration_seconds",
				Help:    "Duration of transaction authorizations in seconds.",
				Buckets: []float64{0.05, 0.1, 0.25, 0.5, 0.75, 1, 2.5},
			},
			[]string{"provider"},
		),
	}
}
