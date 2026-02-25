#!/usr/bin/env bash
# End-to-end demonstration of zero-downtime canary deployment
# This script demonstrates the full deployment workflow

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/colors.sh"

NAMESPACE="transaction-engine"
ROLLOUT_NAME="transaction-engine"
IMAGE_V1="jitapichab/transaction-engine:v1.0.0"
IMAGE_V2="jitapichab/transaction-engine:v2.0.0"

header "Zero-Downtime Deployment Demo"
echo ""
info "This demo shows:"
info "  1. Initial stable deployment (v1)"
info "  2. Background traffic generation"
info "  3. Canary deployment trigger (v2)"
info "  4. Progressive traffic shifting with metrics validation"
info "  5. Automatic promotion or rollback"
echo ""

# Step 1: Check current state
header "Step 1: Current Deployment State"
kubectl argo rollouts get rollout "${ROLLOUT_NAME}" -n "${NAMESPACE}" --no-color 2>/dev/null || {
    warn "No rollout found. Deploy initial version first."
    info "Run: ./scripts/deploy.sh ${IMAGE_V1}"
    exit 1
}
echo ""

# Step 2: Start background traffic
header "Step 2: Generating Background Traffic"
info "Starting load generator (100 req/s for 5 minutes)..."

LOAD_PID=""
cleanup() {
    if [ -n "${LOAD_PID}" ]; then
        kill "${LOAD_PID}" 2>/dev/null || true
    fi
}
trap cleanup EXIT

# Simple load generator using curl
(
    end_time=$((SECONDS + 300))
    while [ $SECONDS -lt $end_time ]; do
        for i in $(seq 1 10); do
            curl -s -X POST "http://localhost:8080/v1/authorize" \
                -H "Content-Type: application/json" \
                -d '{"merchant_id":"merchant_001","amount":99.99,"currency":"USD","card_token":"tok_visa_4242"}' \
                -o /dev/null &
        done
        sleep 0.1
    done
) &
LOAD_PID=$!
success "Traffic generator started (PID: ${LOAD_PID})"
echo ""

# Step 3: Trigger canary deployment
header "Step 3: Triggering Canary Deployment"
info "Deploying new version: ${IMAGE_V2}"
kubectl argo rollouts set image "${ROLLOUT_NAME}" \
    transaction-engine="${IMAGE_V2}" \
    -n "${NAMESPACE}"
success "Canary deployment triggered!"
echo ""

# Step 4: Monitor progress
header "Step 4: Monitoring Canary Progress"
info "Watch the rollout progress below."
info "Open Grafana for real-time metrics: http://localhost:30300/d/transaction-engine-deploy"
info ""
info "Canary steps:"
info "  5% traffic  → analyze 60s → auto-promote or abort"
info "  25% traffic → analyze 60s → auto-promote or abort"
info "  50% traffic → analyze 60s → auto-promote or abort"
info "  100% traffic → done"
echo ""

kubectl argo rollouts get rollout "${ROLLOUT_NAME}" -n "${NAMESPACE}" --watch || {
    error "Rollout was aborted due to metric degradation!"
    info "This demonstrates automatic rollback capability."
}

# Step 5: Final state
echo ""
header "Step 5: Final State"
kubectl argo rollouts get rollout "${ROLLOUT_NAME}" -n "${NAMESPACE}" --no-color
echo ""

# Summary
header "Demo Summary"
info "Grafana Dashboard: http://localhost:30300/d/transaction-engine-deploy"
info "Prometheus:        http://localhost:30900"
info "AlertManager:      http://localhost:30903"
echo ""
success "Demo complete!"
