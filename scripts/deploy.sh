#!/usr/bin/env bash
# Deploy a new version of TransactionEngine via Argo Rollouts canary
# Usage: ./scripts/deploy.sh <image:tag>
# Example: ./scripts/deploy.sh jitapichab/transaction-engine:abc1234

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/colors.sh"

NAMESPACE="transaction-engine"
ROLLOUT_NAME="transaction-engine"

# Cleanup trap
cleanup() {
    local exit_code=$?
    if [ $exit_code -ne 0 ]; then
        error "Deploy failed with exit code ${exit_code}"
        error "Run ./scripts/rollback.sh to rollback"
    fi
}
trap cleanup EXIT

# Validate arguments
if [ $# -lt 1 ]; then
    error "Usage: $0 <image:tag>"
    error "Example: $0 jitapichab/transaction-engine:v2.0.0"
    exit 1
fi

IMAGE_TAG="$1"

# Check prerequisites
command -v kubectl >/dev/null 2>&1 || { error "kubectl not found"; exit 1; }
command -v kubectl-argo-rollouts >/dev/null 2>&1 || { error "kubectl argo rollouts plugin not found"; exit 1; }

header "Deploying TransactionEngine"
info "Image: ${IMAGE_TAG}"
info "Namespace: ${NAMESPACE}"

# Show current state
info "Current rollout status:"
kubectl argo rollouts get rollout "${ROLLOUT_NAME}" -n "${NAMESPACE}" --no-color 2>/dev/null || warn "No existing rollout found"

# Set the new image
header "Triggering canary deployment"
kubectl argo rollouts set image "${ROLLOUT_NAME}" \
    transaction-engine="${IMAGE_TAG}" \
    -n "${NAMESPACE}"

success "Canary deployment triggered"
info "Monitoring rollout progress..."
info "Grafana dashboard: http://localhost:30300/d/transaction-engine-deploy"

# Watch the rollout
kubectl argo rollouts get rollout "${ROLLOUT_NAME}" -n "${NAMESPACE}" --watch || {
    error "Rollout failed or was aborted!"
    error "Run ./scripts/rollback.sh to rollback"
    exit 1
}

success "Deployment completed successfully!"
