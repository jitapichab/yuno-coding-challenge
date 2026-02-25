#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# seed-secrets.sh - Seeds secrets into LocalStack's Secrets Manager
# Run this after setup.sh has deployed LocalStack
# ---------------------------------------------------------------------------
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/colors.sh"

LOCALSTACK_URL="${LOCALSTACK_URL:-http://localhost:4566}"
AWS_REGION="us-east-1"
export AWS_ACCESS_KEY_ID="test"
export AWS_SECRET_ACCESS_KEY="test"
export AWS_DEFAULT_REGION="${AWS_REGION}"

# ---------------------------------------------------------------------------
# Port-forward LocalStack if not already reachable
# ---------------------------------------------------------------------------
header "Seeding secrets into LocalStack Secrets Manager"

PF_PID=""
if ! curl -s "${LOCALSTACK_URL}/_localstack/health" > /dev/null 2>&1; then
    info "Port-forwarding LocalStack..."
    kubectl port-forward -n secrets svc/localstack 4566:4566 &
    PF_PID=$!
    trap "kill ${PF_PID} 2>/dev/null || true" EXIT
    # Wait for port-forward to be ready
    for i in $(seq 1 15); do
        if curl -s "${LOCALSTACK_URL}/_localstack/health" > /dev/null 2>&1; then
            break
        fi
        if [ "$i" -eq 15 ]; then
            error "Timed out waiting for LocalStack port-forward"
            exit 1
        fi
        sleep 1
    done
    success "Port-forward established"
else
    info "LocalStack already reachable at ${LOCALSTACK_URL}"
fi

# ---------------------------------------------------------------------------
# Helper: create or update a secret
# ---------------------------------------------------------------------------
create_or_update_secret() {
    local name=$1
    local value=$2

    if aws --endpoint-url="${LOCALSTACK_URL}" --region "${AWS_REGION}" \
        secretsmanager describe-secret --secret-id "${name}" > /dev/null 2>&1; then
        aws --endpoint-url="${LOCALSTACK_URL}" --region "${AWS_REGION}" \
            secretsmanager put-secret-value \
            --secret-id "${name}" \
            --secret-string "${value}" > /dev/null
        warn "Updated existing secret: ${name}"
    else
        aws --endpoint-url="${LOCALSTACK_URL}" --region "${AWS_REGION}" \
            secretsmanager create-secret \
            --name "${name}" \
            --secret-string "${value}" > /dev/null
        success "Created secret: ${name}"
    fi
}

# ---------------------------------------------------------------------------
# Seed secrets with realistic dummy values
# ---------------------------------------------------------------------------
info "Creating secrets in LocalStack Secrets Manager..."

create_or_update_secret "yuno/transaction-engine/db-connection-string" \
    "postgresql://txn_engine:$(openssl rand -hex 16)@db.internal.yuno.com:5432/transactions?sslmode=require"

create_or_update_secret "yuno/transaction-engine/provider-api-key" \
    "pk_live_$(openssl rand -hex 24)"

create_or_update_secret "yuno/transaction-engine/encryption-key" \
    "$(openssl rand -base64 32)"

echo ""
success "All secrets seeded successfully"
info "ExternalSecret will sync these to K8s Secret 'transaction-engine-secrets' in namespace 'transaction-engine'"
