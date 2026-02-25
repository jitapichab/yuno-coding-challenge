# Zero-Downtime Deployment Infrastructure - Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Build production-grade zero-downtime deployment infrastructure for Yuno's TransactionEngine using canary deployments with Argo Rollouts + Istio on Kind.

**Architecture:** Kind multi-node cluster → Istio service mesh for traffic splitting → Argo Rollouts for progressive canary delivery with automated analysis → kube-prometheus-stack for observability → ESO + LocalStack for PCI-DSS secrets → GitHub Actions CI/CD. Optional Terraform AWS EKS modules.

**Tech Stack:** Go (mock service), Kubernetes (Kind), Istio, Argo Rollouts, Prometheus, Grafana, AlertManager, External Secrets Operator, LocalStack, GitHub Actions, Terraform (AWS)

---

### Task 1: chore(scaffold) - Project structure and configuration

**Files:**
- Create: `CLAUDE.md`
- Create: `.gitignore`
- Create: `README.md` (placeholder)
- Create directories: `mock-service/`, `k8s/base/`, `k8s/app/`, `k8s/mesh/`, `k8s/secrets/`, `k8s/monitoring/`, `terraform/`, `.github/workflows/`, `scripts/`

**Step 1: Create CLAUDE.md from template**

Populate CLAUDE.md with project-specific values:
- PROJECT_NAME: yuno-zero-downtime-deploy
- Description: Zero-downtime deployment infrastructure for TransactionEngine
- Architecture: Kind + Istio + Argo Rollouts + kube-prometheus-stack + ESO
- Fill in Tool Decision Matrix with actual choices

**Step 2: Create .gitignore**

Include: `exercise.md`, `*.tfstate`, `*.tfstate.backup`, `.terraform/`, `bin/`, `mock-service/transaction-engine`, `*.env`, `localstack-data/`, `.idea/`, `.vscode/`, `__debug_bin*`

**Step 3: Create directory structure**

All directories listed above.

**Step 4: Create README.md placeholder**

Minimal header, will be completed in Epic 13.

**Step 5: Commit**
```
chore(scaffold): initialize project structure and configuration
```

---

### Task 2: feat(mock) - Go mock TransactionEngine

**Files:**
- Create: `mock-service/main.go`
- Create: `mock-service/internal/handlers/authorize.go`
- Create: `mock-service/internal/handlers/health.go`
- Create: `mock-service/internal/metrics/metrics.go`
- Create: `mock-service/internal/middleware/logging.go`
- Create: `mock-service/internal/config/config.go`
- Create: `mock-service/main_test.go`
- Create: `mock-service/internal/handlers/authorize_test.go`
- Create: `mock-service/internal/handlers/health_test.go`
- Create: `mock-service/Dockerfile`
- Create: `mock-service/go.mod`
- Create: `mock-service/go.sum`

**Requirements from exercise:**
- Port 8080
- `POST /v1/authorize` - simulates payment authorization (avg 340ms, P99 890ms response time with jitter)
- `GET /health` - returns 200 when ready (after 3-8s startup delay)
- `GET /metrics` - Prometheus format metrics
- Env vars: `DB_CONNECTION_STRING`, `PROVIDER_API_KEY`, `ENCRYPTION_KEY`, `SERVICE_ENV` (must validate all present)
- Graceful shutdown: SIGTERM → stop accepting new requests → drain in-flight → exit
- Structured JSON audit logging for all authorization requests

**Prometheus metrics to expose:**
- `http_requests_total{method, path, status}` - counter
- `http_request_duration_seconds{method, path}` - histogram (buckets: .05, .1, .25, .5, .75, 1, 2.5)
- `http_active_requests{method, path}` - gauge
- `transaction_authorizations_total{status, provider}` - counter
- `transaction_authorization_duration_seconds{provider}` - histogram

**Mock authorize logic:**
- Parse JSON body: `{merchant_id, amount, currency, card_token}`
- Simulate latency: normal distribution mean=340ms, stddev=150ms, cap at 2000ms
- Return 90% approved, 8% declined, 2% error (configurable)
- Response: `{transaction_id, status, provider, timestamp}`
- Structured audit log entry per request

**Dockerfile:**
- Multi-stage: `golang:1.23-alpine` build → `gcr.io/distroless/static-debian12` runtime
- Non-root user (65534)
- Expose 8080

**Tests:**
- Test config validation (missing env vars → error)
- Test /health during startup (503) and after ready (200)
- Test /v1/authorize happy path (200 + valid JSON response)
- Test /v1/authorize bad request (400)
- Test /metrics returns Prometheus format
- Test graceful shutdown (in-flight requests complete)
- Use `httptest.NewServer`, table-driven tests

**Step N: Commit**
```
feat(mock): add TransactionEngine mock service with realistic simulation
```

---

### Task 3: feat(setup) - Bootstrap script

**Files:**
- Create: `scripts/setup.sh`
- Create: `scripts/lib/colors.sh`
- Create: `scripts/lib/checks.sh`

**setup.sh requirements:**
- `set -euo pipefail`
- Colored output (green=success, yellow=warn, red=error, blue=info)
- `trap cleanup EXIT` for failure handling
- Check all required CLIs: `docker`, `kubectl`, `kind`, `helm`, `istioctl`, `kubectl-argo-rollouts`
- Print install instructions for any missing tool
- Idempotent (check if cluster exists before creating)
- Steps:
  1. Create Kind cluster (multi-node: 1 control-plane, 3 workers) with port mappings
  2. Install Istio (ambient or sidecar mode)
  3. Install Argo Rollouts
  4. Install kube-prometheus-stack via Helm
  5. Install External Secrets Operator via Helm
  6. Deploy LocalStack
  7. Create namespaces (transaction-engine, monitoring, istio-system, secrets)
  8. Apply all K8s manifests
  9. Wait for all pods Ready
  10. Print access URLs (Grafana, Prometheus, app)
- Kind config: `kind-config.yaml` with extraPortMappings for 80, 443, 30000-30100

**Step N: Commit**
```
feat(setup): add bootstrap script for local Kind cluster with all addons
```

---

### Task 4: feat(k8s) - Kubernetes base manifests

**Files:**
- Create: `k8s/base/namespace.yaml`
- Create: `k8s/base/service-account.yaml`
- Create: `k8s/base/rbac.yaml`
- Create: `k8s/app/deployment.yaml`
- Create: `k8s/app/service.yaml`
- Create: `k8s/app/hpa.yaml`
- Create: `kind-config.yaml`

**namespace.yaml:** `transaction-engine` namespace with Istio injection label

**service-account.yaml:**
- SA `transaction-engine` in ns `transaction-engine`
- `automountServiceAccountToken: false`

**rbac.yaml:**
- Minimal Role: only read secrets in own namespace
- RoleBinding to SA

**deployment.yaml (will be converted to Rollout in Task 6, but start with Deployment):**
- Replicas: 3
- Container: transaction-engine image
- Port: 8080
- Resource limits: 256Mi memory, 250m CPU; requests: 128Mi, 100m
- Readiness probe: GET /health, initialDelaySeconds: 10, periodSeconds: 5
- Liveness probe: GET /health, initialDelaySeconds: 15, periodSeconds: 10
- Startup probe: GET /health, failureThreshold: 10, periodSeconds: 3 (handles 3-8s startup)
- SecurityContext: runAsNonRoot, readOnlyRootFilesystem, drop ALL caps, seccompProfile RuntimeDefault
- `automountServiceAccountToken: false`
- Env vars from Secret references (not inline values)
- `terminationGracePeriodSeconds: 60`
- Lifecycle preStop hook: `sleep 5` (allow LB to deregister)

**service.yaml:**
- ClusterIP service on port 80 → targetPort 8080
- Labels for Prometheus ServiceMonitor discovery

**hpa.yaml:**
- Min 3, Max 10 replicas
- Target CPU 70%, Memory 80%

**Step N: Commit**
```
feat(k8s): add base Kubernetes manifests with security hardening
```

---

### Task 5: feat(secrets) - External Secrets Operator + LocalStack

**Files:**
- Create: `k8s/secrets/localstack-deployment.yaml`
- Create: `k8s/secrets/localstack-service.yaml`
- Create: `k8s/secrets/secret-store.yaml`
- Create: `k8s/secrets/external-secret.yaml`
- Create: `scripts/seed-secrets.sh`

**LocalStack deployment:** Minimal LocalStack with only `secretsmanager` service enabled.

**seed-secrets.sh:** Uses `awslocal` or `aws --endpoint-url` to create secrets:
- `yuno/transaction-engine/db-connection-string`
- `yuno/transaction-engine/provider-api-key`
- `yuno/transaction-engine/encryption-key`
All with dummy but realistic-looking values (encrypted, rotatable).

**SecretStore:** Points to LocalStack endpoint for AWS Secrets Manager.

**ExternalSecret:** Maps AWS SM paths → K8s Secret `transaction-engine-secrets` with keys: `DB_CONNECTION_STRING`, `PROVIDER_API_KEY`, `ENCRYPTION_KEY`.

**Step N: Commit**
```
feat(secrets): add ESO with LocalStack for PCI-DSS compliant secrets management
```

---

### Task 6: feat(deploy) - Argo Rollouts canary strategy

**Files:**
- Create: `k8s/app/rollout.yaml` (replaces deployment.yaml for Argo Rollouts)
- Create: `k8s/app/analysis-template.yaml`

**rollout.yaml:**
- Convert Deployment spec to Argo Rollout
- Strategy: canary
- Steps:
  1. setWeight: 5 → pause: duration: 60s
  2. setWeight: 25 → pause: duration: 60s
  3. setWeight: 50 → pause: duration: 60s
  4. setWeight: 100
- Analysis at each step via AnalysisTemplate
- Anti-affinity: spread canary and stable across nodes
- `trafficRouting.istio.virtualService` reference
- `trafficRouting.istio.destinationRule` reference
- Rollback: automatic on analysis failure

**analysis-template.yaml:**
- Name: `transaction-engine-analysis`
- Metrics:
  1. `success-rate`: PromQL `sum(rate(http_requests_total{status=~"2..",app="transaction-engine",version="{{args.canary-hash}}"}[2m])) / sum(rate(http_requests_total{app="transaction-engine",version="{{args.canary-hash}}"}[2m]))` — successCondition: `result[0] >= 0.99`
  2. `latency-p99`: PromQL `histogram_quantile(0.99, sum(rate(http_request_duration_seconds_bucket{app="transaction-engine",version="{{args.canary-hash}}"}[2m])) by (le))` — successCondition: `result[0] <= 1.0`
  3. `error-rate`: PromQL for 5xx rate — failureCondition: `result[0] >= 0.01`
- Each metric: interval 30s, count 4, failureLimit 2

**Step N: Commit**
```
feat(deploy): add Argo Rollouts canary strategy with automated analysis
```

---

### Task 7: feat(mesh) - Istio configuration + NetworkPolicies

**Files:**
- Create: `k8s/mesh/virtual-service.yaml`
- Create: `k8s/mesh/destination-rule.yaml`
- Create: `k8s/mesh/gateway.yaml`
- Create: `k8s/mesh/peer-authentication.yaml`
- Create: `k8s/mesh/network-policies.yaml`

**gateway.yaml:** Istio Gateway on port 80 for external traffic

**virtual-service.yaml:**
- Routes to `transaction-engine` service
- Weight-based routing (managed by Argo Rollouts)
- Canary and stable subsets
- Timeout: 5s
- Retries: 2 attempts, 5xx only

**destination-rule.yaml:**
- Subsets: `stable` and `canary` based on `rollouts-pod-template-hash` label
- Connection pool settings (appropriate for payment processing)
- Outlier detection: consecutive5xxErrors=3, interval=30s, ejectionTime=30s

**peer-authentication.yaml:** STRICT mTLS in transaction-engine namespace

**network-policies.yaml:**
- Default deny all ingress/egress in namespace
- Allow ingress only on port 8080 from Istio gateway
- Allow egress to kube-dns (port 53)
- Allow egress to LocalStack (secrets)
- Allow egress to Prometheus (metrics scraping is ingress from Prometheus)

**Step N: Commit**
```
feat(mesh): add Istio traffic management and NetworkPolicies
```

---

### Task 8: feat(monitoring) - Prometheus + Grafana + AlertManager

**Files:**
- Create: `k8s/monitoring/service-monitor.yaml`
- Create: `k8s/monitoring/prometheus-rules.yaml`
- Create: `k8s/monitoring/alertmanager-config.yaml`
- Create: `k8s/monitoring/grafana-dashboard.json`
- Create: `k8s/monitoring/grafana-dashboard-configmap.yaml`

**service-monitor.yaml:**
- Selects transaction-engine pods
- Scrape /metrics on port 8080, interval 15s
- Relabel to add `version` label from pod labels

**prometheus-rules.yaml:**
Recording rules:
- `transaction_engine:http_request_success_rate:rate5m`
- `transaction_engine:http_request_duration_p50:rate5m`
- `transaction_engine:http_request_duration_p95:rate5m`
- `transaction_engine:http_request_duration_p99:rate5m`
- `transaction_engine:active_requests:sum`

Alert rules:
- `TransactionEngineHighErrorRate` — >1% errors for 2m → critical
- `TransactionEngineHighLatency` — P99 >1s for 5m → warning
- `TransactionEngineHighLatencyCritical` — P99 >2s for 2m → critical
- `TransactionEnginePodCrashLooping` → critical
- `TransactionEngineDeploymentStalled` — rollout not progressing for 10m → warning
- `TransactionEngineNoTraffic` — 0 requests for 5m → critical

**alertmanager-config.yaml:**
- Route by severity:
  - `critical` → `pagerduty-receiver` (with PD integration key reference)
  - `warning` → `slack-receiver` (with webhook URL reference)
- Inhibition: critical silences warning for same alertname
- Group by: alertname, namespace
- Group wait: 30s, group interval: 5m, repeat interval: 4h

**grafana-dashboard.json:** Complete dashboard with panels:
- Row 1: Overview — Request Rate, Success Rate, Active Requests, Error Rate
- Row 2: Latency — P50/P95/P99 timeseries, Latency Heatmap
- Row 3: Deployment — Old vs New version request rate, Old vs New error rate, Old vs New latency, Rollout progress
- Row 4: Resources — CPU/Memory usage by version, Pod count by version
- Row 5: SLO — Error budget burn rate, SLO compliance gauge
- All panels with `version` variable for filtering
- Template variables: `namespace`, `version`

**Step N: Commit**
```
feat(monitoring): add Prometheus rules, Grafana dashboard, and AlertManager config
```

---

### Task 9: feat(sli-slo) - SLI/SLO definitions

**Files:**
- Create: `k8s/monitoring/sli-slo-rules.yaml`
- Modify: `k8s/monitoring/prometheus-rules.yaml` (add burn-rate alerts)

**SLI definitions:**
1. **Availability SLI**: Proportion of successful HTTP requests (2xx+3xx / total) — Target SLO: 99.95%
2. **Latency SLI**: Proportion of requests completing in <1000ms — Target SLO: 99.0%
3. **Authorization Success SLI**: Proportion of authorization requests not returning 5xx — Target SLO: 99.99%

**Recording rules for SLO:**
- 5m, 30m, 1h, 6h, 24h windows for each SLI
- Error budget remaining calculation
- Burn rate calculation (actual error rate / allowed error rate)

**Burn-rate alerts (multi-window):**
- 1h burn rate >14.4 AND 5m burn rate >14.4 → critical (page)
- 6h burn rate >6 AND 30m burn rate >6 → critical
- 24h burn rate >3 AND 2h burn rate >3 → warning
- 72h burn rate >1 AND 6h burn rate >1 → warning (ticket)

**Step N: Commit**
```
feat(sli-slo): add SLI/SLO definitions with multi-window burn-rate alerts
```

---

### Task 10: ci(pipeline) - GitHub Actions CI/CD

**Files:**
- Create: `.github/workflows/ci.yml`
- Create: `.github/workflows/deploy.yml`

**ci.yml (on push/PR):**
- Jobs:
  1. `lint`: golangci-lint on mock-service
  2. `test`: go test with coverage on mock-service
  3. `build`: docker build, tag with SHA and semver
  4. `push`: push to DockerHub (only on main branch merge)
  5. `security-scan`: trivy scan on built image
- All actions pinned to SHA versions
- Secrets via GitHub Actions secrets (DOCKERHUB_USERNAME, DOCKERHUB_TOKEN)

**deploy.yml (manual trigger with inputs):**
- Inputs: `image_tag` (required), `environment` (staging/production)
- Jobs:
  1. `validate`: dry-run apply of manifests
  2. `deploy`: Update Argo Rollout image, monitor rollout status
  3. `verify`: Run smoke tests against deployed version
  4. `notify`: Post deployment status to Slack webhook
- For production: require manual approval (GitHub Environments)

**Step N: Commit**
```
ci(pipeline): add GitHub Actions CI/CD with progressive deployment
```

---

### Task 11: feat(automation) - Operational scripts

**Files:**
- Create: `scripts/deploy.sh`
- Create: `scripts/rollback.sh`
- Create: `scripts/demo.sh`
- Create: `scripts/port-forward.sh`
- Create: `scripts/load-test.sh`

**deploy.sh:**
- Usage: `./scripts/deploy.sh <image:tag>`
- Updates Argo Rollout image
- Watches rollout progress with colored output
- Exits 0 on success, 1 on rollback

**rollback.sh:**
- Usage: `./scripts/rollback.sh`
- Triggers `kubectl argo rollouts abort` then `undo`
- Watches until stable
- Prints status

**demo.sh:**
- End-to-end demonstration script:
  1. Show current deployment status
  2. Send traffic to /v1/authorize (background)
  3. Trigger canary deployment with new version
  4. Show Argo Rollout status progressing through steps
  5. Show Grafana dashboard URL with old vs new comparison
  6. Show rollout completing (or triggering rollback if bad version)
  7. Print summary

**load-test.sh:**
- Simple load generator using `curl` in parallel or `hey` if available
- Configurable RPS and duration
- Outputs results

**port-forward.sh:**
- Port-forward Grafana (3000), Prometheus (9090), app (8080)
- Backgrounded with PID tracking for cleanup

**Step N: Commit**
```
feat(automation): add deploy, rollback, demo, and operational scripts
```

---

### Task 12: feat(terraform) - AWS EKS modules (optional)

**Files:**
- Create: `terraform/modules/networking/main.tf`
- Create: `terraform/modules/networking/variables.tf`
- Create: `terraform/modules/networking/outputs.tf`
- Create: `terraform/modules/eks/main.tf`
- Create: `terraform/modules/eks/variables.tf`
- Create: `terraform/modules/eks/outputs.tf`
- Create: `terraform/modules/eks/iam.tf`
- Create: `terraform/environments/production/main.tf`
- Create: `terraform/environments/production/variables.tf`
- Create: `terraform/environments/production/outputs.tf`
- Create: `terraform/environments/production/terraform.tfvars.example`
- Create: `terraform/environments/staging/main.tf`
- Create: `terraform/environments/staging/variables.tf`

**networking module:** VPC, public/private subnets, NAT gateway, security groups

**eks module:** EKS cluster, managed node groups (3 nodes), IRSA for ESO, OIDC provider, addons (CoreDNS, kube-proxy, vpc-cni)

**environments/production:** Uses modules with production values. terraform.tfvars.example with safe defaults.

**environments/staging:** Uses modules with smaller/cheaper values.

**Step N: Commit**
```
feat(terraform): add AWS EKS infrastructure modules for cloud deployment
```

---

### Task 13: docs(final) - Complete documentation

**Files:**
- Create/Rewrite: `DESIGN.md`
- Create: `SETUP.md`
- Rewrite: `README.md`

**DESIGN.md sections (7+ substantive):**
1. Introduction & Context — Black Friday scenario, business impact
2. Architecture Overview — Component diagram, data flow
3. Why Canary Over Blue-Green — Quantified trade-offs (15s downtime at 7000 req/min = 1,750 failed transactions)
4. Tool Choices — Every tool with alternatives considered and cost comparison
5. Secrets & PCI-DSS — Real vs simulated, what production would need
6. What I Got Wrong Initially — Honest mistakes and corrections
7. Failure Scenarios — 5+ scenarios with recovery steps
8. SLI/SLO Rationale — Why these numbers, how they map to business impact
9. Production vs Exercise — What I'd do differently with unlimited time
10. Cost Analysis — Real monthly pricing for AWS (EKS, EC2, NAT, etc.)
11. Security: Real vs Theater — Honest about local limitations

**SETUP.md sections:**
1. Prerequisites with versions and install links
2. Quick start (`./scripts/setup.sh`)
3. Manual steps (10+)
4. How to trigger a deployment
5. How to view dashboards (Grafana URL, Prometheus URL)
6. How to perform rollback
7. Troubleshooting (4+ scenarios)
8. Teardown

**README.md sections:**
1. Problem → Solution table
2. ASCII architecture diagram
3. Tech stack with justification
4. Directory tree with descriptions
5. Quick start
6. Deployment workflow
7. Monitoring & Metrics
8. Rollback procedure
9. Security controls (real vs simulated)
10. Failure scenarios table

**Step N: Commit**
```
docs(final): add DESIGN.md, SETUP.md, and complete README.md
```

---

### Task 14: fix(security) + refactor(hardening) - OWASP + Production patterns

**Files:**
- Audit and fix ALL existing files
- Create: `k8s/base/encryption-config.yaml` (reference manifest)
- Modify: any files with security issues

**OWASP checks:**
- A01: Verify no unauthenticated admin/internal endpoints exposed
- A02: Verify no API docs enabled, seccomp on all pods, SA tokens not mounted
- A03: Verify CI actions pinned to SHA, all deps pinned
- A05: Verify no shell injection in scripts, no template injection
- A06: Verify bounded data structures, rate limiting on mock service
- A09: Verify no secrets in logs, audit trail working
- A10: Verify fail-closed error handling everywhere

**Production hardening:**
- Structured audit logger (JSON) for security events
- Circuit breaker pattern for mock service (if calling external)
- Bounded data structures with max size + eviction
- EncryptionConfiguration reference for etcd encryption at rest
- Graceful shutdown verification (preStop + SIGTERM)

**Step N: Two commits**
```
fix(security): harden against OWASP Top 10 findings
refactor(hardening): add production patterns and bounded data structures
```

---

## Execution Batches (Parallel where possible)

```
Batch 1: [Task 1: scaffold] → commit sequentially
Batch 2: [Task 2: mock] + [Task 3: setup] → parallel agents, commit sequentially
Batch 3: [Task 4: k8s] + [Task 5: secrets] → parallel agents, commit sequentially
Batch 4: [Task 6: deploy] + [Task 7: mesh] + [Task 8: monitoring] → parallel, commit sequentially
Batch 5: [Task 9: sli-slo] + [Task 10: ci-pipeline] + [Task 11: automation] → parallel, commit sequentially
Batch 6: [Task 12: terraform] → commit
Batch 7: [Task 13: docs] → commit
Batch 8: [Task 14: security] → 2 commits
```

Total: 15 commits (14 epics, Task 14 = 2 commits)
