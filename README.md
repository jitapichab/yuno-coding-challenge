# Yuno Zero-Downtime Deployment Infrastructure

> Zero-downtime deployment infrastructure for TransactionEngine -- Yuno's core payment processing microservice handling 7,000+ requests/minute with a 99.95% availability SLO.

---

## Problem and Solution

| Problem | Solution |
|---------|----------|
| 15-45s downtime per deployment | Argo Rollouts canary with Istio traffic splitting (5% -> 25% -> 50% -> 100%) |
| No automated health validation | AnalysisTemplates querying Prometheus for success rate, P99 latency, and error rate |
| 4 minutes to detect issues | Real-time multi-window burn-rate alerts with 30s evaluation intervals |
| No rollback capability | Automatic rollback on metric degradation + one-command manual rollback |
| Secrets in plain text | External Secrets Operator + AWS Secrets Manager (LocalStack for local dev) |
| No deployment visibility | Grafana dashboard with old vs new version side-by-side comparison |

---

## Architecture

```
┌──────────────┐     ┌─────────────────────────────────────────────┐
│   GitHub     │     │            Kind Cluster                      │
│   Actions    │────>│  ┌─────────┐    ┌──────────────────┐        │
│  (CI/CD)     │     │  │  Istio  │    │  Argo Rollouts   │        │
└──────────────┘     │  │ Gateway │    │  (Controller)    │        │
                     │  └────┬────┘    └────────┬─────────┘        │
                     │       │                  │                   │
                     │  ┌────▼────────────────┐ │                   │
                     │  │   VirtualService     │ │                   │
                     │  │  (weight-based)      │ │                   │
                     │  └────┬───────┬────────┘ │                   │
                     │       │       │          │                   │
                     │  ┌────▼──┐ ┌──▼────┐    │                   │
                     │  │Stable │ │Canary │<───┘                   │
                     │  │ (v1)  │ │ (v2)  │                        │
                     │  │ 95%   │ │  5%   │                        │
                     │  └───┬───┘ └───┬───┘                        │
                     │      │         │                             │
                     │  ┌───▼─────────▼───┐                        │
                     │  │   Prometheus     │──> Grafana             │
                     │  │ (metrics scrape) │   AlertManager         │
                     │  └─────────────────┘                        │
                     │                                              │
                     │  ┌─────────────┐  ┌──────────────┐          │
                     │  │ LocalStack  │  │    ESO        │          │
                     │  │ (AWS SM)    │<─│ (secrets)     │          │
                     │  └─────────────┘  └──────────────┘          │
                     └─────────────────────────────────────────────┘
```

**Traffic flow during a canary deployment:**

1. Istio Gateway receives incoming requests
2. VirtualService routes traffic by weight (e.g., 95% stable / 5% canary)
3. Argo Rollouts controller manages weight progression through steps
4. AnalysisTemplate queries Prometheus at each step to validate canary health
5. If metrics degrade, Argo Rollouts automatically aborts and routes 100% back to stable
6. If all steps pass, canary is promoted to stable and receives 100% traffic

---

## Tech Stack

| Component | Tool | Why This Tool |
|-----------|------|---------------|
| Container orchestration | Kubernetes (Kind) | Multi-node local cluster simulates production topology with 3 availability zones |
| Service mesh | Istio | Weight-based traffic splitting required for canary; mTLS for PCI-DSS; retries and circuit breaking built-in |
| Progressive delivery | Argo Rollouts | Native Istio integration, AnalysisTemplate-driven auto-promotion/rollback, declarative canary steps |
| Monitoring | kube-prometheus-stack | Prometheus + Grafana + AlertManager in one Helm chart; ServiceMonitor CRDs for auto-discovery |
| Secrets management | ESO + LocalStack | External Secrets Operator syncs from AWS Secrets Manager; LocalStack simulates AWS locally; production-ready pattern |
| CI/CD | GitHub Actions | Native to GitHub repos; SHA-pinned actions for supply chain security; separate CI and deploy workflows |
| Cloud IaC | Terraform (AWS EKS) | Modular EKS + VPC configuration for production deployment; reviewable without provisioning resources |
| Mock service | Go | Same language as the real TransactionEngine; realistic Prometheus metrics, startup delay, graceful shutdown |
| Container image | Distroless | Minimal attack surface; no shell, no package manager; runs as non-root (UID 65534) |

---

## Directory Structure

```
.
├── .github/
│   └── workflows/
│       ├── ci.yml                      # CI: lint, test, build, push, security scan (Trivy)
│       └── deploy.yml                  # CD: validate, deploy to staging or production
├── k8s/
│   ├── app/
│   │   ├── analysis-template.yaml      # Prometheus-based canary health checks (success rate, P99, error rate)
│   │   ├── deployment.yaml             # Standard Deployment (reference, not used with Rollouts)
│   │   ├── hpa.yaml                    # HorizontalPodAutoscaler (CPU/memory-based scaling)
│   │   ├── rollout.yaml                # Argo Rollout with canary strategy (5%->25%->50%->100%)
│   │   ├── service.yaml                # Primary ClusterIP service
│   │   └── services.yaml               # Stable + canary service definitions for Istio routing
│   ├── base/
│   │   ├── namespace.yaml              # Namespace definition with Istio injection label
│   │   ├── rbac.yaml                   # RBAC roles scoped to transaction-engine namespace
│   │   └── service-account.yaml        # Dedicated ServiceAccount (automountServiceAccountToken: false)
│   ├── mesh/
│   │   ├── destination-rule.yaml       # Connection pooling, outlier detection, canary/stable subsets
│   │   ├── gateway.yaml                # Istio Gateway for external traffic ingress
│   │   ├── network-policies.yaml       # Default-deny + allow-list: Istio, DNS, monitoring, mesh
│   │   ├── peer-authentication.yaml    # STRICT mTLS between all pods in namespace
│   │   └── virtual-service.yaml        # Weight-based routing (Argo Rollouts manages weights)
│   ├── monitoring/
│   │   ├── alertmanager-config.yaml    # Routing: critical->PagerDuty, warning->Slack, inhibition rules
│   │   ├── grafana-dashboard.json      # TransactionEngine deployment dashboard (old vs new comparison)
│   │   ├── grafana-dashboard-configmap.yaml  # ConfigMap to auto-provision the Grafana dashboard
│   │   ├── prometheus-rules.yaml       # Recording rules + alert rules (error rate, latency, crash loops)
│   │   ├── service-monitor.yaml        # ServiceMonitor for Prometheus auto-discovery of app metrics
│   │   └── sli-slo-rules.yaml         # SLI/SLO recording rules + multi-window burn-rate alerts
│   └── secrets/
│       ├── external-secret.yaml        # ExternalSecret mapping AWS SM keys to K8s Secret
│       ├── localstack-credentials.yaml # AWS credentials for ESO to authenticate with LocalStack
│       ├── localstack-deployment.yaml  # LocalStack Deployment + Service (Secrets Manager simulator)
│       └── secret-store.yaml           # ClusterSecretStore pointing to LocalStack endpoint
├── mock-service/
│   ├── Dockerfile                      # Multi-stage build: golang:1.23-alpine -> distroless (non-root)
│   ├── go.mod / go.sum                 # Go module dependencies (prometheus client)
│   ├── main.go                         # Entry point: startup delay, graceful shutdown, HTTP server
│   ├── main_test.go                    # Integration tests for the full server lifecycle
│   └── internal/
│       ├── config/config.go            # Environment variable loading + validation
│       ├── handlers/
│       │   ├── authorize.go            # POST /v1/authorize - simulated payment authorization
│       │   ├── authorize_test.go       # Unit tests for authorization handler
│       │   ├── health.go               # GET /health - readiness-gated health endpoint
│       │   └── health_test.go          # Unit tests for health handler
│       ├── metrics/metrics.go          # Prometheus metrics: request count, duration histogram, active reqs
│       └── middleware/logging.go       # Structured JSON audit logging middleware
├── scripts/
│   ├── setup.sh                        # One-command bootstrap: Kind + Istio + Argo + Prometheus + ESO + LocalStack
│   ├── deploy.sh                       # Trigger canary deployment with a new image tag
│   ├── rollback.sh                     # Abort in-progress rollout + undo to previous version
│   ├── demo.sh                         # End-to-end demonstration with traffic generation
│   ├── port-forward.sh                 # Start/stop port-forwards for all services
│   ├── load-test.sh                    # Load testing with 'hey' or curl fallback
│   ├── seed-secrets.sh                 # Seed secrets into LocalStack Secrets Manager
│   └── lib/
│       ├── colors.sh                   # Colored terminal output helpers
│       └── checks.sh                   # Prerequisite binary checks with install instructions
├── terraform/
│   ├── environments/
│   │   ├── staging/                    # Staging environment: smaller instances, lower costs
│   │   └── production/                 # Production environment: HA node groups, private subnets
│   └── modules/
│       ├── eks/                        # EKS cluster, managed node groups, IRSA, OIDC
│       └── networking/                 # VPC, subnets (public/private), NAT gateway, security groups
├── kind-config.yaml                    # 4-node cluster: 1 control-plane + 3 workers across 3 zones
└── README.md                           # This file
```

---

## Quick Start

### Prerequisites

| Tool | Minimum Version | Install |
|------|-----------------|---------|
| Docker | >= 24.x | https://docs.docker.com/get-docker/ |
| kubectl | >= 1.28 | https://kubernetes.io/docs/tasks/tools/ |
| kind | >= 0.20 | https://kind.sigs.k8s.io/docs/user/quick-start/#installation |
| Helm | >= 3.12 | https://helm.sh/docs/intro/install/ |
| istioctl | >= 1.20 | https://istio.io/latest/docs/setup/getting-started/#download |
| kubectl-argo-rollouts | >= 1.6 | https://argo-rollouts.readthedocs.io/en/stable/installation/#kubectl-plugin-installation |

### Bootstrap Everything

```bash
./scripts/setup.sh
```

This single command creates a Kind cluster, installs Istio, Argo Rollouts, kube-prometheus-stack, External Secrets Operator, and LocalStack. It is idempotent and safe to re-run.

### Seed Secrets (after setup)

```bash
./scripts/seed-secrets.sh
```

Seeds realistic dummy credentials into LocalStack's Secrets Manager. ESO syncs them to a Kubernetes Secret in the `transaction-engine` namespace.

### Access Services

```bash
./scripts/port-forward.sh start
```

| Service | URL | Credentials |
|---------|-----|-------------|
| TransactionEngine | http://localhost:8080 | -- |
| Grafana | http://localhost:3000 | admin / admin |
| Prometheus | http://localhost:9090 | -- |
| AlertManager | http://localhost:9093 | -- |
| LocalStack | http://localhost:4566 | -- |

---

## Deployment Workflow

### 1. Trigger a Canary Deployment

```bash
./scripts/deploy.sh jitapichab/transaction-engine:v2.0.0
```

### 2. What Happens Automatically

| Step | Traffic to Canary | Duration | Validation |
|------|-------------------|----------|------------|
| 1 | 5% | 60 seconds | AnalysisTemplate: success rate >= 99%, P99 <= 1s, error rate < 1% |
| 2 | 25% | 60 seconds | Same metrics re-evaluated |
| 3 | 50% | 60 seconds | Same metrics re-evaluated |
| 4 | 100% | -- | Promotion complete, canary becomes new stable |

At each step, the AnalysisTemplate runs 4 Prometheus queries at 30-second intervals. If any metric fails more than once (failureLimit: 1), the rollout is automatically aborted and traffic returns to 100% stable.

### 3. Monitor Progress

```bash
# Terminal: watch rollout status
kubectl argo rollouts get rollout transaction-engine -n transaction-engine --watch

# Browser: open Grafana dashboard
open http://localhost:3000/d/transaction-engine-deploy
```

### 4. Manual Promotion (if paused)

```bash
kubectl argo rollouts promote transaction-engine -n transaction-engine
```

---

## Monitoring and Metrics

### Key Metrics

| Metric | Type | Description |
|--------|------|-------------|
| `http_requests_total` | Counter | Total HTTP requests by status code and version |
| `http_request_duration_seconds` | Histogram | Request latency distribution (P50, P95, P99) |
| `http_active_requests` | Gauge | Currently in-flight requests |
| `transaction_authorizations_total` | Counter | Authorization results by outcome (success, declined, error) |

### SLI/SLO Definitions

| SLI | Definition | SLO Target | Error Budget (30d) |
|-----|-----------|------------|-------------------|
| Availability | Non-5xx responses / total responses | 99.95% | ~3.5 errors/min at 7000 req/min |
| Latency | Requests completing in < 1s / total | 99.0% | ~70 slow requests/min at 7000 req/min |

### Grafana Dashboard

The pre-provisioned "TransactionEngine Deployment" dashboard (`grafana-dashboard.json`) includes:

- Request rate by version (old vs new comparison)
- Error rate by version (old vs new comparison)
- Latency percentiles (P50, P95, P99) by version
- Active request count
- Canary weight progression timeline
- Error budget remaining gauges

### Prometheus Queries

```promql
# Current success rate
sum(rate(http_requests_total{app="transaction-engine",status=~"2.."}[5m]))
/
sum(rate(http_requests_total{app="transaction-engine"}[5m]))

# P99 latency
histogram_quantile(0.99,
  sum(rate(http_request_duration_seconds_bucket{app="transaction-engine"}[5m])) by (le)
)

# Error budget remaining (availability)
transaction_engine:availability_error_budget:remaining

# Burn rate (availability, 1h window)
transaction_engine:availability_burn_rate:1h
```

### Alerts

| Alert | Condition | Severity | Response |
|-------|-----------|----------|----------|
| TransactionEngineHighErrorRate | Error rate > 1% for 2m | Critical | Page on-call, investigate immediately |
| TransactionEngineHighLatencyP99 | P99 > 1s for 5m | Warning | File ticket, investigate within shift |
| TransactionEngineHighLatencyCritical | P99 > 2s for 2m | Critical | Page on-call, customers affected |
| TransactionEnginePodCrashLooping | Restarts > 0 for 10m | Critical | Check logs, resource limits |
| TransactionEngineNoTraffic | 0 requests for 5m | Critical | Routing issue, check VirtualService |
| SLO Availability Burn Rate (Tier 1) | 14.4x burn for 1h + 5m | Critical | Budget exhausts in ~2 days, page immediately |
| SLO Availability Burn Rate (Tier 2) | 6x burn for 6h + 30m | Critical | Budget exhausts in ~5 days, file ticket |
| SLO Availability Burn Rate (Tier 3) | 3x burn for 24h + 1h | Warning | Budget exhausts in ~10 days, investigate |
| Error Budget Exhausted | Budget < 0% | Critical | SLO breached, change freeze |

AlertManager routes critical alerts to PagerDuty and warnings to a Slack channel (`#payment-alerts`). Inhibition rules prevent duplicate notifications when both critical and warning fire for the same alertname.

---

## Rollback Procedure

### Automatic Rollback

If the AnalysisTemplate detects metric degradation during a canary deployment, Argo Rollouts automatically:

1. Aborts the rollout
2. Scales down canary pods
3. Routes 100% of traffic back to the stable version
4. No manual intervention required

### Manual Rollback

```bash
./scripts/rollback.sh
```

This script:

1. Checks the current rollout state
2. Aborts any in-progress rollout
3. Reverts to the previous stable revision
4. Watches until the rollback completes

### Emergency Rollback (direct kubectl)

```bash
# Abort current rollout
kubectl argo rollouts abort transaction-engine -n transaction-engine

# Revert to previous version
kubectl argo rollouts undo transaction-engine -n transaction-engine
```

---

## Security Controls

| Control | Implementation | Status |
|---------|---------------|--------|
| mTLS between services | Istio PeerAuthentication STRICT mode | Real (in-cluster) |
| Non-root containers | Distroless base image, UID 65534, readOnlyRootFilesystem | Real |
| Secrets encryption at rest | ESO + AWS Secrets Manager (LocalStack locally) | Simulated (LocalStack); Real pattern for production |
| Network segmentation | Default-deny NetworkPolicies + explicit allow-list | Real (in-cluster) |
| Container image scanning | Trivy in CI pipeline (CRITICAL, HIGH) | Real |
| Supply chain security | GitHub Actions pinned to commit SHA | Real |
| RBAC least privilege | Dedicated ServiceAccount, scoped Roles | Real |
| SecurityContext hardening | Drop ALL capabilities, seccompProfile: RuntimeDefault | Real |
| No automounted SA tokens | `automountServiceAccountToken: false` | Real |
| Audit logging | Structured JSON logs from middleware | Real (application-level) |
| AlertManager routing | Critical -> PagerDuty, Warning -> Slack | Simulated (no real PagerDuty/Slack endpoints) |

---

## Failure Scenarios

| Scenario | Detection | Automatic Recovery | Manual Recovery |
|----------|-----------|-------------------|-----------------|
| New version returns 5xx errors | AnalysisTemplate `error-rate` check fails (>= 1%) | Argo Rollouts aborts canary, 100% to stable | `./scripts/rollback.sh` |
| New version has high latency | AnalysisTemplate `latency-p99` check fails (> 1s) | Argo Rollouts aborts canary, 100% to stable | `./scripts/rollback.sh` |
| New version crashes on startup | Startup probe fails after 10 attempts (30s) | Pod stays NotReady, no traffic routed to it | Check logs: `kubectl logs -n transaction-engine -l app=transaction-engine` |
| Database connection lost | Health endpoint returns 503, readiness probe fails | Pod removed from service endpoints, no traffic | Restore DB, pod auto-recovers via readiness probe |
| Canary pod OOM killed | Container restart detected by crash-looping alert | Alert fires, rollout pauses on failure | Increase memory limits, redeploy |
| Istio sidecar not injected | No metrics from pod, VirtualService routing fails | AnalysisTemplate fails (no data = failure) | Check namespace label: `kubectl label ns transaction-engine istio-injection=enabled` |
| Secrets not syncing | ExternalSecret status shows error | Pod fails to start (missing env vars) | Check SecretStore + LocalStack: `kubectl describe externalsecret -n transaction-engine` |
| All pods crash simultaneously | TransactionEngineNoTraffic alert fires (0 req for 5m) | N/A (requires manual investigation) | Check events: `kubectl get events -n transaction-engine --sort-by='.lastTimestamp'` |

---

## Load Testing

```bash
# Default: 50 req/s for 60 seconds
./scripts/load-test.sh

# Custom: 200 req/s for 120 seconds
./scripts/load-test.sh 200 120
```

The load test uses [hey](https://github.com/rakyll/hey) if available, with a curl-based fallback. It targets `POST /v1/authorize` and reports success rate, latency distribution, and RPS.

---

## End-to-End Demo

```bash
./scripts/demo.sh
```

This script runs a complete demonstration:

1. Verifies the current stable deployment
2. Starts background traffic generation (~100 req/s for 5 minutes)
3. Triggers a canary deployment to v2
4. Monitors the canary progression through all steps (5% -> 25% -> 50% -> 100%)
5. Reports final state and dashboard URLs

---

## Terraform (Production AWS EKS)

The `terraform/` directory contains modular IaC for deploying to AWS EKS in production. It is organized as:

- `modules/networking/` -- VPC with public/private subnets, NAT gateway
- `modules/eks/` -- EKS cluster, managed node groups, IRSA, OIDC provider
- `environments/staging/` -- Smaller instance types, lower replica counts
- `environments/production/` -- HA configuration, private subnets, production-grade node groups

```bash
cd terraform/environments/production
cp terraform.tfvars.example terraform.tfvars
# Edit terraform.tfvars with your values
terraform init
terraform plan
terraform apply
```

---

## Teardown

```bash
kind delete cluster --name yuno
```

This removes the entire Kind cluster and all resources within it.

---

## Further Reading

- [Argo Rollouts Documentation](https://argo-rollouts.readthedocs.io/)
- [Istio Traffic Management](https://istio.io/latest/docs/concepts/traffic-management/)
- [Google SRE Workbook - Alerting on SLOs](https://sre.google/workbook/alerting-on-slos/)
- [External Secrets Operator](https://external-secrets.io/)
- [kube-prometheus-stack](https://github.com/prometheus-community/helm-charts/tree/main/charts/kube-prometheus-stack)
