#!/usr/bin/env bash
# Rollback TransactionEngine to the previous stable version
# Usage: ./scripts/rollback.sh

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/colors.sh"

NAMESPACE="transaction-engine"
ROLLOUT_NAME="transaction-engine"

# Cleanup trap
cleanup() {
    local exit_code=$?
    if [ $exit_code -ne 0 ]; then
        error "Rollback failed with exit code ${exit_code}"
    fi
}
trap cleanup EXIT

header "Rolling back TransactionEngine"

# Show current state
info "Current rollout status:"
kubectl argo rollouts get rollout "${ROLLOUT_NAME}" -n "${NAMESPACE}" --no-color

# Abort if in progress
PHASE=$(kubectl argo rollouts status "${ROLLOUT_NAME}" -n "${NAMESPACE}" --timeout 1s 2>/dev/null || echo "Progressing")
if [[ "${PHASE}" == *"Paused"* ]] || [[ "${PHASE}" == *"Progressing"* ]]; then
    warn "Rollout is in progress, aborting first..."
    kubectl argo rollouts abort "${ROLLOUT_NAME}" -n "${NAMESPACE}"
    info "Waiting for abort to complete..."
    sleep 5
fi

# Undo to previous version
kubectl argo rollouts undo "${ROLLOUT_NAME}" -n "${NAMESPACE}"
success "Rollback initiated"

# Watch until stable
info "Waiting for rollback to complete..."
kubectl argo rollouts get rollout "${ROLLOUT_NAME}" -n "${NAMESPACE}" --watch

success "Rollback completed successfully!"
info "Verify service health: curl http://localhost:8080/health"
