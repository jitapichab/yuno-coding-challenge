#!/usr/bin/env bash
# Port-forward all services for local access
# Usage: ./scripts/port-forward.sh [start|stop]

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/colors.sh"

PID_DIR="${SCRIPT_DIR}/.pids"
mkdir -p "${PID_DIR}"

start_forward() {
    local name=$1 namespace=$2 service=$3 local_port=$4 remote_port=$5

    # Kill existing if running
    if [ -f "${PID_DIR}/${name}.pid" ]; then
        local old_pid
        old_pid=$(cat "${PID_DIR}/${name}.pid")
        kill "${old_pid}" 2>/dev/null || true
        rm -f "${PID_DIR}/${name}.pid"
    fi

    kubectl port-forward -n "${namespace}" "svc/${service}" "${local_port}:${remote_port}" &
    echo $! > "${PID_DIR}/${name}.pid"
    info "${name}: http://localhost:${local_port}"
}

stop_all() {
    header "Stopping all port-forwards"
    for pid_file in "${PID_DIR}"/*.pid; do
        if [ -f "${pid_file}" ]; then
            local pid
            pid=$(cat "${pid_file}")
            kill "${pid}" 2>/dev/null || true
            rm -f "${pid_file}"
        fi
    done
    success "All port-forwards stopped"
}

case "${1:-start}" in
    start)
        header "Starting port-forwards"
        start_forward "grafana"      "monitoring"          "kube-prometheus-stack-grafana"       3000 80
        start_forward "prometheus"   "monitoring"          "kube-prometheus-stack-prometheus"     9090 9090
        start_forward "alertmanager" "monitoring"          "kube-prometheus-stack-alertmanager"   9093 9093
        start_forward "app"          "transaction-engine"  "transaction-engine"                   8080 80
        start_forward "localstack"   "secrets"             "localstack"                           4566 4566
        echo ""
        success "All services accessible:"
        info "  App:          http://localhost:8080"
        info "  Grafana:      http://localhost:3000  (admin/admin)"
        info "  Prometheus:   http://localhost:9090"
        info "  AlertManager: http://localhost:9093"
        info "  LocalStack:   http://localhost:4566"
        echo ""
        info "Run '$0 stop' to stop all port-forwards"
        ;;
    stop)
        stop_all
        ;;
    *)
        error "Usage: $0 [start|stop]"
        exit 1
        ;;
esac
