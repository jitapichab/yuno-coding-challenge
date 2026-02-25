#!/usr/bin/env bash
# Simple load test for TransactionEngine
# Usage: ./scripts/load-test.sh [rps] [duration_seconds]
# Example: ./scripts/load-test.sh 100 60

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/colors.sh"

RPS="${1:-50}"
DURATION="${2:-60}"
URL="${TRANSACTION_ENGINE_URL:-http://localhost:8080}"
CONCURRENCY=$((RPS / 10 + 1))

header "Load Test: TransactionEngine"
info "Target:      ${URL}"
info "Rate:        ${RPS} req/s"
info "Duration:    ${DURATION}s"
info "Concurrency: ${CONCURRENCY} workers"
echo ""

# Check if hey is available (preferred load testing tool)
if command -v hey >/dev/null 2>&1; then
    info "Using 'hey' for load testing"
    hey -z "${DURATION}s" \
        -q "${RPS}" \
        -c "${CONCURRENCY}" \
        -m POST \
        -H "Content-Type: application/json" \
        -d '{"merchant_id":"load-test-merchant","amount":49.99,"currency":"USD","card_token":"tok_visa_4242"}' \
        "${URL}/v1/authorize"
else
    warn "'hey' not installed. Using curl-based load test (less accurate)."
    info "Install hey: go install github.com/rakyll/hey@latest"
    echo ""

    SUCCESS=0
    FAILURE=0
    TOTAL=0
    START_TIME=$SECONDS

    while [ $((SECONDS - START_TIME)) -lt "${DURATION}" ]; do
        for _ in $(seq 1 "${CONCURRENCY}"); do
            if curl -s -f -X POST "${URL}/v1/authorize" \
                -H "Content-Type: application/json" \
                -d '{"merchant_id":"load-test-merchant","amount":49.99,"currency":"USD","card_token":"tok_visa_4242"}' \
                -o /dev/null --max-time 5; then
                SUCCESS=$((SUCCESS + 1))
            else
                FAILURE=$((FAILURE + 1))
            fi
            TOTAL=$((TOTAL + 1))
        done
        sleep "$(echo "scale=3; 1 / (${RPS} / ${CONCURRENCY})" | bc 2>/dev/null || echo "0.1")"
    done

    ELAPSED=$((SECONDS - START_TIME))
    echo ""
    header "Results"
    info "Total requests: ${TOTAL}"
    info "Successful:     ${SUCCESS}"
    info "Failed:         ${FAILURE}"
    info "Duration:       ${ELAPSED}s"
    info "Actual RPS:     $(echo "scale=1; ${TOTAL} / ${ELAPSED}" | bc 2>/dev/null || echo "N/A")"

    if [ "${FAILURE}" -gt 0 ]; then
        ERROR_RATE=$(echo "scale=4; ${FAILURE} / ${TOTAL} * 100" | bc 2>/dev/null || echo "N/A")
        warn "Error rate: ${ERROR_RATE}%"
    else
        success "Zero errors!"
    fi
fi
