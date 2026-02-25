# Zero-Downtime Deployment Infrastructure Design

## Context
Black Friday deployment for Yuno's TransactionEngine — a Go microservice processing 7K req/min (bursting to 12K). Must deploy a critical hotfix with zero transaction loss. Current deployments cause 15-45s of elevated errors.

## Architecture

### Components
- **Mock TransactionEngine (Go)**: Realistic simulation of the real service (port 8080, Prometheus metrics, startup delay, graceful shutdown)
- **Kind cluster** (multi-node): Local Kubernetes for development and demo
- **Istio**: Service mesh for precise traffic splitting during canary rollouts
- **Argo Rollouts**: Progressive delivery with automated canary analysis
- **kube-prometheus-stack**: Prometheus + Grafana + AlertManager
- **ESO + LocalStack**: External Secrets Operator simulating AWS Secrets Manager (PCI-DSS)
- **GitHub Actions**: CI/CD pipeline (build, test, push, deploy)
- **Terraform (optional)**: AWS EKS modules for production cloud deployment

### Deployment Strategy: Canary with Argo Rollouts + Istio
1. Deploy new version as canary (0% traffic)
2. Shift 5% traffic → analyze metrics (60s)
3. Shift 25% traffic → analyze metrics (60s)
4. Shift 50% traffic → analyze metrics (60s)
5. Shift 100% traffic → promote
6. Auto-rollback if error rate >1% or P99 >1000ms at any step

### Secrets Management
- ExternalSecrets Operator reads from LocalStack (AWS Secrets Manager simulation)
- Secrets never in code, env vars, or git
- Audit trail via structured JSON logging
- Maps directly to production AWS SM workflow

### Monitoring Stack
- Prometheus: metrics collection, recording rules, alerting rules
- Grafana: deployment dashboard with old vs new version comparison
- AlertManager: severity-based routing (critical/warning)
- SLI/SLO: availability >99.95%, latency P99 <1000ms

### Traffic Flow
```
Client → Istio Gateway → VirtualService (weight-based) → DestinationRule
  ├── stable (v1): weight = 100-canary%
  └── canary (v2): weight = canary%
```

## Key Decisions
1. **Canary over blue-green**: Lower resource cost, gradual validation, better for high-traffic payment system
2. **Istio over Nginx Ingress**: Precise percentage-based traffic splitting, mutual TLS, observability
3. **ESO over SealedSecrets**: Real secrets manager workflow, rotation support, audit trail
4. **Plain YAML over Kustomize/Helm**: Simpler to review, no template abstraction layer
5. **Go mock**: Same language as real service, demonstrates domain understanding

## Trade-offs
- Istio adds complexity but provides the traffic splitting precision needed for zero-downtime
- ESO + LocalStack requires more setup but demonstrates production-grade secrets management
- Kind cluster is local-only but Terraform modules show cloud deployment path

## Approved
Date: 2026-02-25
