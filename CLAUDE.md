# yuno-zero-downtime-deploy

## Language
All code, comments, documentation, commit messages, and variable names MUST be in **English**. No exceptions.

## Project Overview
Zero-downtime deployment infrastructure for Yuno's TransactionEngine — a payment processing microservice requiring canary deployments with automated rollback for Black Friday traffic.

## Architecture
- **Kind** multi-node cluster for local Kubernetes
- **Istio** service mesh for precise traffic splitting (VirtualService + DestinationRule)
- **Argo Rollouts** for progressive canary delivery with AnalysisTemplates
- **kube-prometheus-stack** for Prometheus + Grafana + AlertManager
- **External Secrets Operator + LocalStack** for PCI-DSS compliant secrets management
- **GitHub Actions** for CI/CD pipeline
- **Terraform** (optional) for AWS EKS production deployment
- Plain YAML manifests (no Kustomize/Helm for app)

## Tool Choices
| Component | Tool | Justification |
|-----------|------|---------------|
| Local K8s | Kind (multi-node) | Realistic cluster, fast setup, free |
| Traffic splitting | Istio | Precise weight-based canary, mTLS, native Argo Rollouts integration |
| Progressive delivery | Argo Rollouts | Best-in-class canary with automated analysis + auto-rollback |
| Monitoring | kube-prometheus-stack | All-in-one: Prometheus + Grafana + AlertManager |
| Secrets | ESO + LocalStack | Production-grade AWS SM workflow, testable locally |
| CI/CD | GitHub Actions | Native GitHub integration, widely adopted |
| IaC (cloud) | Terraform | Industry standard, modular, reviewable |
| Mock service | Go | Same language as real TransactionEngine |

## Code Standards
- **Dockerfiles**: multi-stage, non-root (65534), distroless/alpine base, no secrets in layers
- **K8s manifests**: resource limits, readiness/liveness/startup probes, `seccompProfile: RuntimeDefault`, `automountServiceAccountToken: false`, `readOnlyRootFilesystem: true`, drop ALL caps
- **Scripts**: `set -euo pipefail`, `command -v` checks, colored output, trap cleanup
- **Secrets**: never in code, env vars, images, logs, or git history
- **Data structures**: bounded with max size and eviction
- **Error handling**: fail-closed — on error deny, never allow
- **Graceful shutdown**: SIGTERM handler, drain in-flight requests, preStop hooks

## Go Standards (mock-service)
- Standard library preferred, minimal external deps
- `context.Context` propagation on all handlers
- `net/http` graceful shutdown with `srv.Shutdown(ctx)`
- Table-driven tests with `httptest.NewServer`
- Structured JSON logging

## Commit Conventions
- Conventional Commits: `type(scope): description`
- Types: `feat`, `fix`, `docs`, `chore`, `ci`, `test`, `refactor`
- Each commit = one self-contained epic
- Minimum 12 commits

## Directory Layout
```
/
├── mock-service/              # Go mock TransactionEngine
│   ├── internal/              # handlers, metrics, config, middleware
│   ├── main.go
│   ├── Dockerfile
│   └── *_test.go
├── k8s/
│   ├── base/                  # Namespace, RBAC, ServiceAccount
│   ├── app/                   # Rollout, Service, HPA
│   ├── mesh/                  # Istio VirtualService, DestinationRule, NetworkPolicies
│   ├── secrets/               # ExternalSecret, SecretStore, LocalStack
│   └── monitoring/            # PrometheusRule, ServiceMonitor, Grafana dashboard
├── terraform/                 # AWS EKS (optional)
│   ├── modules/
│   └── environments/
├── .github/workflows/         # CI/CD pipelines
├── scripts/                   # setup.sh, deploy.sh, rollback.sh, demo.sh
├── docs/plans/                # Design and implementation plans
├── CLAUDE.md
├── DESIGN.md
├── SETUP.md
└── README.md
```
