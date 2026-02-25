package main

import (
	"context"
	"fmt"
	"log/slog"
	"math/rand"
	"net/http"
	"os"
	"os/signal"
	"sync/atomic"
	"syscall"
	"time"

	"github.com/prometheus/client_golang/prometheus"
	"github.com/prometheus/client_golang/prometheus/promhttp"

	"github.com/jitapichab/yuno-coding-challenge/mock-service/internal/config"
	"github.com/jitapichab/yuno-coding-challenge/mock-service/internal/handlers"
	"github.com/jitapichab/yuno-coding-challenge/mock-service/internal/metrics"
	"github.com/jitapichab/yuno-coding-challenge/mock-service/internal/middleware"
)

func main() {
	// Structured JSON logger.
	logger := slog.New(slog.NewJSONHandler(os.Stdout, &slog.HandlerOptions{
		Level: slog.LevelInfo,
	}))
	slog.SetDefault(logger)

	// Load and validate configuration.
	cfg, err := config.Load()
	if err != nil {
		logger.Error("failed to load configuration", "error", err)
		os.Exit(1)
	}

	logger.Info("configuration loaded",
		"service_env", cfg.ServiceEnv,
		"port", cfg.Port,
	)

	// Prometheus metrics registry.
	reg := prometheus.NewRegistry()
	reg.MustRegister(prometheus.NewProcessCollector(prometheus.ProcessCollectorOpts{}))
	reg.MustRegister(prometheus.NewGoCollector())
	m := metrics.New(reg)

	// Readiness flag - starts as not ready.
	ready := &atomic.Bool{}

	// Create handlers.
	healthHandler := handlers.NewHealthHandler(ready)
	authorizeHandler := handlers.NewAuthorizeHandler(m, logger)

	// Setup HTTP mux.
	mux := http.NewServeMux()
	mux.Handle("/health", healthHandler)
	mux.Handle("/metrics", promhttp.HandlerFor(reg, promhttp.HandlerOpts{
		EnableOpenMetrics: false,
	}))
	mux.Handle("/v1/authorize", middleware.MetricsMiddleware(m)(authorizeHandler))

	srv := &http.Server{
		Addr:         ":" + cfg.Port,
		Handler:      mux,
		ReadTimeout:  15 * time.Second,
		WriteTimeout: 30 * time.Second,
		IdleTimeout:  60 * time.Second,
	}

	// Start server in background.
	go func() {
		logger.Info("starting HTTP server", "addr", srv.Addr)
		if err := srv.ListenAndServe(); err != nil && err != http.ErrServerClosed {
			logger.Error("HTTP server error", "error", err)
			os.Exit(1)
		}
	}()

	// Simulate startup delay (DB pool initialization, etc).
	startupDelay := time.Duration(3+rand.Intn(6)) * time.Second
	logger.Info("simulating startup delay", "duration", startupDelay.String())
	time.Sleep(startupDelay)

	// Mark as ready.
	ready.Store(true)
	logger.Info("service is ready")

	// Wait for shutdown signal.
	quit := make(chan os.Signal, 1)
	signal.Notify(quit, syscall.SIGTERM, syscall.SIGINT)
	sig := <-quit
	logger.Info("received shutdown signal", "signal", sig.String())

	// Graceful shutdown: stop accepting new connections, drain in-flight.
	ready.Store(false)
	logger.Info("starting graceful shutdown")

	shutdownCtx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()

	if err := srv.Shutdown(shutdownCtx); err != nil {
		logger.Error("graceful shutdown failed", "error", err)
		os.Exit(1)
	}

	logger.Info("server stopped gracefully")
	fmt.Fprintln(os.Stderr, "server stopped")
}
