#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# checks.sh - Prerequisite checks for the setup script
# ---------------------------------------------------------------------------

check_prerequisites() {
    local missing=0

    header "Step 0: Checking prerequisites"

    # -- docker ---------------------------------------------------------------
    if command -v docker &>/dev/null; then
        success "docker is installed ($(docker --version 2>/dev/null | head -1))"
    else
        error "docker is NOT installed"
        info  "  Install: https://docs.docker.com/get-docker/"
        missing=$((missing + 1))
    fi

    # -- kubectl --------------------------------------------------------------
    if command -v kubectl &>/dev/null; then
        success "kubectl is installed ($(kubectl version --client --short 2>/dev/null || kubectl version --client 2>/dev/null | head -1))"
    else
        error "kubectl is NOT installed"
        info  "  Install: https://kubernetes.io/docs/tasks/tools/install-kubectl/"
        missing=$((missing + 1))
    fi

    # -- kind -----------------------------------------------------------------
    if command -v kind &>/dev/null; then
        success "kind is installed ($(kind version 2>/dev/null))"
    else
        error "kind is NOT installed"
        info  "  Install: https://kind.sigs.k8s.io/docs/user/quick-start/#installation"
        missing=$((missing + 1))
    fi

    # -- helm -----------------------------------------------------------------
    if command -v helm &>/dev/null; then
        success "helm is installed ($(helm version --short 2>/dev/null))"
    else
        error "helm is NOT installed"
        info  "  Install: https://helm.sh/docs/intro/install/"
        missing=$((missing + 1))
    fi

    # -- istioctl -------------------------------------------------------------
    if command -v istioctl &>/dev/null; then
        success "istioctl is installed ($(istioctl version --remote=false 2>/dev/null || echo 'unknown version'))"
    else
        error "istioctl is NOT installed"
        info  "  Install: https://istio.io/latest/docs/setup/getting-started/#download"
        missing=$((missing + 1))
    fi

    # -- kubectl-argo-rollouts ------------------------------------------------
    if kubectl argo rollouts version &>/dev/null; then
        success "kubectl-argo-rollouts plugin is installed ($(kubectl argo rollouts version 2>/dev/null | head -1))"
    else
        error "kubectl-argo-rollouts plugin is NOT installed"
        info  "  Install: https://argoproj.github.io/argo-rollouts/installation/#kubectl-plugin-installation"
        missing=$((missing + 1))
    fi

    # -- verdict --------------------------------------------------------------
    if [[ $missing -gt 0 ]]; then
        error "$missing prerequisite(s) missing. Please install them and re-run."
        exit 1
    fi

    success "All prerequisites satisfied"
}
