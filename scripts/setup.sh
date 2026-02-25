#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# setup.sh - Bootstrap a local Kind cluster with Istio, Argo Rollouts,
#            Prometheus stack, External Secrets Operator, and LocalStack
#            for the Yuno zero-downtime deployment exercise.
# ---------------------------------------------------------------------------
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# shellcheck source=lib/colors.sh
source "${SCRIPT_DIR}/lib/colors.sh"
# shellcheck source=lib/checks.sh
source "${SCRIPT_DIR}/lib/checks.sh"

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------
CLUSTER_NAME="yuno"
KIND_CONFIG="${PROJECT_ROOT}/kind-config.yaml"
WAIT_TIMEOUT="300s"

# ---------------------------------------------------------------------------
# Cleanup trap
# ---------------------------------------------------------------------------
cleanup() {
    local exit_code=$?
    if [ $exit_code -ne 0 ]; then
        error "Setup failed with exit code $exit_code"
        error "Run 'kind delete cluster --name ${CLUSTER_NAME}' to clean up"
    fi
}
trap cleanup EXIT

# ===================================================================
# Step 0 - Prerequisites
# ===================================================================
check_prerequisites

# ===================================================================
# Step 1 - Create Kind cluster
# ===================================================================
header "Step 1: Create Kind cluster (${CLUSTER_NAME})"

if kind get clusters 2>/dev/null | grep -q "^${CLUSTER_NAME}$"; then
    warn "Kind cluster '${CLUSTER_NAME}' already exists -- skipping creation"
else
    info "Creating Kind cluster '${CLUSTER_NAME}' from ${KIND_CONFIG} ..."
    kind create cluster --config "${KIND_CONFIG}"
    success "Kind cluster '${CLUSTER_NAME}' created"
fi

# Make sure kubectl context is pointing at the new cluster
info "Setting kubectl context to kind-${CLUSTER_NAME}"
kubectl cluster-info --context "kind-${CLUSTER_NAME}" >/dev/null 2>&1
success "kubectl context set to kind-${CLUSTER_NAME}"

# ===================================================================
# Step 2 - Create namespaces
# ===================================================================
header "Step 2: Create namespaces"

for ns in transaction-engine monitoring secrets argo-rollouts external-secrets; do
    if kubectl get namespace "${ns}" >/dev/null 2>&1; then
        warn "Namespace '${ns}' already exists -- skipping"
    else
        kubectl create namespace "${ns}"
        success "Namespace '${ns}' created"
    fi
done

# ===================================================================
# Step 3 - Install Istio
# ===================================================================
header "Step 3: Install Istio (default profile)"

if kubectl get namespace istio-system >/dev/null 2>&1 && \
   kubectl get deployment istiod -n istio-system >/dev/null 2>&1; then
    warn "Istio appears to be installed already -- skipping"
else
    info "Installing Istio with default profile ..."
    istioctl install --set profile=default -y
    success "Istio installed"
fi

info "Enabling automatic sidecar injection on 'transaction-engine' namespace"
kubectl label namespace transaction-engine istio-injection=enabled --overwrite
success "Sidecar injection enabled for 'transaction-engine'"

# ===================================================================
# Step 4 - Install Argo Rollouts
# ===================================================================
header "Step 4: Install Argo Rollouts"

if kubectl get deployment argo-rollouts -n argo-rollouts >/dev/null 2>&1; then
    warn "Argo Rollouts appears to be installed already -- skipping"
else
    info "Applying Argo Rollouts manifests (v1.7.2) ..."
    kubectl apply -n argo-rollouts \
        -f https://github.com/argoproj/argo-rollouts/releases/download/v1.7.2/install.yaml
    success "Argo Rollouts installed in 'argo-rollouts' namespace"
fi

# ===================================================================
# Step 5 - Add Helm repositories
# ===================================================================
header "Step 5: Add Helm repositories"

add_helm_repo() {
    local name="$1" url="$2"
    if helm repo list 2>/dev/null | grep -q "^${name}"; then
        warn "Helm repo '${name}' already added -- skipping"
    else
        helm repo add "${name}" "${url}"
        success "Helm repo '${name}' added"
    fi
}

add_helm_repo "prometheus-community" "https://prometheus-community.github.io/helm-charts"
add_helm_repo "external-secrets" "https://charts.external-secrets.io"

info "Updating Helm repos ..."
helm repo update
success "Helm repos updated"

# ===================================================================
# Step 6 - Install kube-prometheus-stack
# ===================================================================
header "Step 6: Install kube-prometheus-stack"

if helm list -n monitoring 2>/dev/null | grep -q "kube-prometheus-stack"; then
    warn "kube-prometheus-stack is already installed -- skipping"
else
    info "Installing kube-prometheus-stack via Helm (this may take a few minutes) ..."
    helm install kube-prometheus-stack prometheus-community/kube-prometheus-stack \
        --version 65.1.0 \
        --namespace monitoring \
        --set grafana.adminPassword=admin \
        --set grafana.service.type=NodePort \
        --set grafana.service.nodePort=30300 \
        --set prometheus.service.type=NodePort \
        --set prometheus.service.nodePort=30900 \
        --set alertmanager.service.type=NodePort \
        --set alertmanager.service.nodePort=30903 \
        --wait --timeout "${WAIT_TIMEOUT}"
    success "kube-prometheus-stack installed in 'monitoring' namespace"
fi

# ===================================================================
# Step 7 - Install External Secrets Operator
# ===================================================================
header "Step 7: Install External Secrets Operator"

if helm list -n external-secrets 2>/dev/null | grep -q "external-secrets"; then
    warn "External Secrets Operator is already installed -- skipping"
else
    info "Installing External Secrets Operator via Helm ..."
    helm install external-secrets external-secrets/external-secrets \
        --version 0.10.7 \
        --namespace external-secrets \
        --set installCRDs=true \
        --wait --timeout "${WAIT_TIMEOUT}"
    success "External Secrets Operator installed in 'external-secrets' namespace"
fi

# ===================================================================
# Step 8 - Deploy LocalStack
# ===================================================================
header "Step 8: Deploy LocalStack (Secrets Manager)"

if kubectl get deployment localstack -n secrets >/dev/null 2>&1; then
    warn "LocalStack deployment already exists -- skipping"
else
    info "Creating LocalStack deployment and service in 'secrets' namespace ..."
    kubectl apply -f - <<'LOCALSTACK_EOF'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: localstack
  namespace: secrets
  labels:
    app: localstack
spec:
  replicas: 1
  selector:
    matchLabels:
      app: localstack
  template:
    metadata:
      labels:
        app: localstack
    spec:
      automountServiceAccountToken: false
      securityContext:
        seccompProfile:
          type: RuntimeDefault
      containers:
        - name: localstack
          image: localstack/localstack:3.4
          ports:
            - containerPort: 4566
              name: edge
          env:
            - name: SERVICES
              value: "secretsmanager"
            - name: DEBUG
              value: "0"
            - name: EAGER_SERVICE_LOADING
              value: "1"
          securityContext:
            allowPrivilegeEscalation: false
            capabilities:
              drop:
                - "ALL"
          readinessProbe:
            httpGet:
              path: /_localstack/health
              port: 4566
            initialDelaySeconds: 10
            periodSeconds: 5
          livenessProbe:
            httpGet:
              path: /_localstack/health
              port: 4566
            initialDelaySeconds: 15
            periodSeconds: 10
          resources:
            requests:
              memory: "256Mi"
              cpu: "250m"
            limits:
              memory: "512Mi"
              cpu: "500m"
---
apiVersion: v1
kind: Service
metadata:
  name: localstack
  namespace: secrets
  labels:
    app: localstack
spec:
  selector:
    app: localstack
  ports:
    - protocol: TCP
      port: 4566
      targetPort: 4566
      name: edge
  type: ClusterIP
LOCALSTACK_EOF
    success "LocalStack deployed in 'secrets' namespace"
fi

# ===================================================================
# Step 9 - Wait for all pods to be Ready
# ===================================================================
header "Step 9: Waiting for all pods to be Ready (timeout ${WAIT_TIMEOUT})"

NAMESPACES_TO_CHECK=("istio-system" "argo-rollouts" "monitoring" "external-secrets" "secrets")

for ns in "${NAMESPACES_TO_CHECK[@]}"; do
    info "Waiting for pods in namespace '${ns}' ..."
    # Get all deployments in the namespace and wait for each
    deployments=$(kubectl get deployments -n "${ns}" -o jsonpath='{.items[*].metadata.name}' 2>/dev/null || true)
    if [[ -z "${deployments}" ]]; then
        warn "No deployments found in '${ns}' -- skipping"
        continue
    fi
    for deploy in ${deployments}; do
        info "  Waiting for deployment '${deploy}' in '${ns}' ..."
        if kubectl rollout status deployment/"${deploy}" -n "${ns}" --timeout="${WAIT_TIMEOUT}"; then
            success "  Deployment '${deploy}' in '${ns}' is Ready"
        else
            error "  Deployment '${deploy}' in '${ns}' failed to become Ready within timeout"
            exit 1
        fi
    done
done

success "All pods are Ready"

# ===================================================================
# Step 10 - Summary
# ===================================================================
header "Step 10: Setup Complete"

info "Cluster '${CLUSTER_NAME}' is up and running with:"
info "  - Istio (default profile) with sidecar injection on 'transaction-engine'"
info "  - Argo Rollouts in 'argo-rollouts' namespace"
info "  - kube-prometheus-stack in 'monitoring' namespace"
info "  - External Secrets Operator in 'external-secrets' namespace"
info "  - LocalStack (Secrets Manager) in 'secrets' namespace"
echo ""
info "Access URLs:"
success "  Grafana:      http://localhost:30300  (admin / admin)"
success "  Prometheus:   http://localhost:30900"
success "  AlertManager: http://localhost:30903"
echo ""
info "Namespaces:"
kubectl get namespaces | grep -E "transaction-engine|monitoring|secrets|argo-rollouts|external-secrets|istio-system"
echo ""
success "Setup finished successfully. Happy deploying!"
