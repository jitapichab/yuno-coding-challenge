# Design Decisions & Reasoning

**Author:** Jose Itapichab
**Date:** February 25, 2026
**Subject:** Zero-Downtime Deployment Infrastructure for Yuno TransactionEngine

---

## Table of Contents

1. [Context & Problem Statement](#1-context--problem-statement)
2. [Architecture Overview](#2-architecture-overview)
3. [Why Canary Over Blue-Green](#3-why-canary-over-blue-green)
4. [Tool Choices & Alternatives Considered](#4-tool-choices--alternatives-considered)
5. [Secrets Management & PCI-DSS Considerations](#5-secrets-management--pci-dss-considerations)
6. [What I Got Wrong Initially](#6-what-i-got-wrong-initially)
7. [Failure Scenarios & Recovery](#7-failure-scenarios--recovery)
8. [SLI/SLO Rationale](#8-slislo-rationale)
9. [Production vs Exercise](#9-production-vs-exercise)
10. [Cost Analysis](#10-cost-analysis)
11. [Security: Real vs Theater](#11-security-real-vs-theater)

---

## 1. Context & Problem Statement

I built this infrastructure to solve a very specific, high-stakes problem: Yuno's TransactionEngine needs a critical hotfix deployed before Black Friday, but every deployment for the past six months has caused 15-45 seconds of elevated errors. That is unacceptable for a payment processing service.

Let me put the numbers in context:

- **Normal load:** 7,000 requests/minute sustained, 12,000 at peak hours.
- **Black Friday projected peak:** 127,000 transactions/minute (an 18x spike over normal).
- **Cost of 15 seconds of downtime at normal load:** At 7,000 req/min, 15 seconds = approximately 1,750 failed transactions. Each failed transaction is a merchant who saw a checkout error, a customer who might not retry, and revenue Yuno does not earn.
- **Cost of 15 seconds of downtime during Black Friday peak:** At 127,000 txn/min, 15 seconds = approximately 31,750 failed transactions. That is not a bad metric -- that is a catastrophic incident and a potential breach of merchant SLAs.

The VP of Infrastructure made the mandate clear: **zero transaction loss during deployment**. Not "low error rate." Zero. That constraint shaped every decision I made.

The existing deployment process was a basic rolling update with no traffic management, no automated health validation, and no way to limit the blast radius of a bad release. When pods restarted, in-flight requests were dropped. New pods received traffic before they finished initializing their database connection pools (3-8 seconds of startup). There was no mechanism to detect that the new version was degrading performance until someone noticed manually -- which historically took 4 minutes.

I needed to build:
1. A deployment strategy that keeps the old version serving traffic until the new version is **proven** healthy.
2. Automated metric validation that catches regressions in seconds, not minutes.
3. Automatic rollback so a human does not have to be watching the deploy at 2am.
4. Proper secrets management because this is a payment service handling PCI-DSS-scoped credentials.

---

## 2. Architecture Overview

### Component Diagram

```
                           External Traffic
                                 |
                                 v
                    +------------------------+
                    |   Istio IngressGateway |
                    |   (port 80/443)        |
                    +------------------------+
                                 |
                                 v
                    +------------------------+
                    |   VirtualService       |
                    |   (traffic splitting)  |
                    |   stable: X%           |
                    |   canary:  Y%          |
                    +------------------------+
                          /            \
                         v              v
              +----------------+  +----------------+
              | DestinationRule|  | DestinationRule|
              | subset: stable |  | subset: canary |
              +----------------+  +----------------+
                    |                    |
                    v                    v
          +------------------+  +------------------+
          | Stable Pods (3)  |  | Canary Pod (1)   |
          | Envoy Sidecar    |  | Envoy Sidecar    |
          | (mTLS)           |  | (mTLS)           |
          +------------------+  +------------------+
                    |                    |
                    v                    v
          +------------------+  +------------------+
          | /metrics (8080)  |  | /metrics (8080)  |
          +------------------+  +------------------+
                    \                  /
                     v                v
              +--------------------------+
              |  ServiceMonitor          |
              |  (Prometheus scraping)   |
              +--------------------------+
                         |
                         v
              +--------------------------+
              |  Prometheus              |
              |  (recording rules,       |
              |   burn-rate alerts)      |
              +--------------------------+
                    /           \
                   v             v
          +-------------+  +------------------+
          | Grafana     |  | AlertManager     |
          | Dashboard   |  | PagerDuty/Slack  |
          +-------------+  +------------------+
                                 ^
                                 |
              +--------------------------+
              | Argo Rollouts Controller |
              | AnalysisTemplate queries |
              | Prometheus for canary    |
              | health validation        |
              +--------------------------+

          +----------------------------------------------+
          |              Secrets Flow                     |
          |                                              |
          | ExternalSecret ---> ClusterSecretStore        |
          |                         |                    |
          |                         v                    |
          |              LocalStack (local) /             |
          |              AWS Secrets Manager (prod)       |
          +----------------------------------------------+
```

### Data Flow During Normal Operation

1. Client sends `POST /v1/authorize` to the Istio IngressGateway.
2. The Gateway terminates external connections and forwards to the VirtualService.
3. The VirtualService routes 100% of traffic to the `stable` subset via `transaction-engine-stable` Service.
4. The DestinationRule applies connection pooling (100 max connections, 100 max requests per connection) and outlier detection (eject pods after 3 consecutive 5xx errors for 30 seconds).
5. The Envoy sidecar in each pod enforces STRICT mTLS (PeerAuthentication) -- all pod-to-pod communication is encrypted.
6. The TransactionEngine container processes the request, selects a payment provider, simulates authorization latency (normal distribution, mean 340ms, stddev 150ms), and returns the result.
7. Prometheus scrapes `/metrics` every 15 seconds via the ServiceMonitor, collecting `http_requests_total`, `http_request_duration_seconds`, and `transaction_authorizations_total`.

### Data Flow During Canary Rollout

1. Engineer runs `./scripts/deploy.sh jitapichab/transaction-engine:v2.0.0`.
2. Argo Rollouts creates one canary pod with the new image.
3. The VirtualService weights shift to 95% stable / 5% canary.
4. AnalysisTemplate begins querying Prometheus every 30 seconds, measuring:
   - Success rate (must be >= 99%)
   - P99 latency (must be <= 1.0 second)
   - Error rate (must be < 1%)
5. After 60 seconds at 5%, if all metrics pass, weights shift to 75/25, then 50/50, then 0/100.
6. If any metric fails for more than 1 measurement (failureLimit: 1 across 4 measurements), Argo Rollouts **automatically aborts** the canary and reverts to 100% stable.
7. No traffic is lost at any step because the stable pods continue serving the majority of traffic throughout the process.

---

## 3. Why Canary Over Blue-Green

This was the first major design decision and the one that shapes everything else. I chose canary deployment over blue-green and rolling update. Here is the quantified reasoning:

### Quantified Comparison

| Factor | Blue-Green | Canary (this solution) | Rolling Update |
|--------|-----------|----------------------|----------------|
| **Traffic switch** | Instant (0% -> 100%) | Gradual (5% -> 25% -> 50% -> 100%) | Gradual but uncontrolled |
| **Blast radius at first exposure** | 100% of traffic | 5% of traffic (350 req/min at 7K baseline) | ~25% initially (1 pod out of 4) |
| **Resource overhead** | 2x entire fleet (6 pods) | ~1 extra pod (33% overhead) | 0 extra (but maxSurge usually adds 1) |
| **Rollback speed** | Instant (switch DNS/LB back) | Instant (revert VirtualService weights) | Slow (re-roll all pods) |
| **Traffic control granularity** | None -- all or nothing | Precise percentages via Istio | None -- load-balancer distributes evenly |
| **Data-driven promotion** | Manual validation after switch | Automated via AnalysisTemplates | No built-in validation |
| **Risk of silent regression** | High -- 100% traffic hits new version immediately | Low -- only 5% initially, with automated metric checking | High -- eventually 100% with no validation gates |

### The math that decided it

At 7,000 req/min with canary at 5%: **only 350 req/min hit the new version initially**. If the new version has a latent bug that surfaces at runtime (the exact scenario we are fixing -- a concurrency timeout under load), only 350 req/min are affected while Argo Rollouts detects the anomaly. With blue-green, all 7,000 req/min hit the new version the moment you flip the switch.

During Black Friday at 127,000 txn/min, that 5% canary means ~6,350 txn/min on the canary. Still a lot, but the stable fleet is absorbing the other 120,650 txn/min safely. With blue-green at that scale, a bad switch means 127,000 txn/min on a broken version.

The cost argument is also compelling: blue-green requires doubling the fleet during deployment. With 3 replicas at 128Mi-256Mi RAM each, canary adds approximately 1 pod (~256Mi) versus blue-green adding 3 pods (~768Mi). At scale on AWS with `t3.medium` instances, this difference grows linearly with the fleet size.

### Why not rolling update?

Rolling updates are the Kubernetes default and I considered them briefly. The problem is they provide no traffic control. When a new pod becomes Ready, it immediately receives an equal share of traffic. There is no way to say "only send 5% to this pod while I validate it." Rolling updates also lack any concept of automated analysis -- there is no built-in mechanism to compare the new version's error rate against the old version and abort if it degrades. For a payment service where the VP said "zero transaction loss," I needed the fine-grained traffic control and automated validation that only canary + service mesh provides.

---

## 4. Tool Choices & Alternatives Considered

For every tool in this stack, I evaluated at least one alternative. I document the reasoning here because tool selection for a payment service is not about personal preference -- it is about matching capabilities to constraints.

### Kubernetes Cluster: Kind

| | Kind (chosen) | minikube | k3s |
|---|---|---|---|
| **Multi-node** | Yes (1 CP + 3 workers) | Single node only (without profiles) | Yes |
| **Docker-native** | Yes (runs in Docker containers) | VM-based (slower startup) | Runs directly on host |
| **Port mapping** | extraPortMappings in config | --ports flag | Built-in |
| **Teardown speed** | ~5 seconds | ~30 seconds | ~10 seconds |
| **Production fidelity** | High (full K8s API) | Medium (some API differences) | Medium (stripped-down K8s) |
| **Monthly cost** | $0 (local) | $0 (local) | $0 (local) |

I chose Kind because I needed a **multi-node cluster** to test `topologySpreadConstraints` and pod anti-affinity -- these are critical for ensuring that stable and canary pods are distributed across nodes so a single node failure does not take down the entire fleet. Kind gives me 3 worker nodes labeled with different zones (`zone-a`, `zone-b`, `zone-c`) in a configuration file, and tears down in seconds when I need to iterate.

### Service Mesh: Istio

| | Istio (chosen) | Nginx Ingress + annotations | Linkerd |
|---|---|---|---|
| **Traffic splitting** | Precise % via VirtualService | Weight annotations (less reliable, eventually consistent) | TrafficSplit CRD (SMI spec) |
| **mTLS** | STRICT mode, automatic cert rotation | Not built-in (requires separate cert-manager) | On by default, automatic |
| **Outlier detection** | DestinationRule with consecutive5xxErrors, ejection | Not built-in | Circuit breaking via ServiceProfile |
| **Argo Rollouts integration** | First-class (native Istio traffic routing) | Supported but with caveats | Supported via SMI |
| **Sidecar overhead** | ~50MB RAM per sidecar | N/A (no sidecar) | ~10MB RAM per sidecar |
| **Learning curve** | Steep | Gentle | Moderate |
| **Monthly cost (AWS)** | $0 (sidecar overhead only) | $0 | $0 |

I chose Istio despite its complexity because of one critical capability: **precise traffic splitting with Argo Rollouts integration**. Argo Rollouts has first-class support for Istio VirtualServices -- it directly modifies the weight fields during canary progression. With Nginx Ingress, Argo Rollouts uses annotation-based traffic splitting which is less reliable (it relies on the ingress controller's implementation of weighted routing, which can be eventually consistent and imprecise at low percentages like 5%).

The mTLS enforcement was a bonus. For a PCI-DSS-scoped service handling payment credentials, all inter-service communication must be encrypted. Istio gives me this with a single PeerAuthentication resource set to STRICT mode -- no application code changes required.

The outlier detection in the DestinationRule (`consecutive5xxErrors: 3`, `baseEjectionTime: 30s`) acts as an additional safety net: if any individual pod starts returning 5xx errors, Envoy ejects it from the load balancing pool before the AnalysisTemplate even detects the problem at the aggregate level.

### Deployment Controller: Argo Rollouts

| | Argo Rollouts (chosen) | Flagger | Spinnaker |
|---|---|---|---|
| **CRD-based** | Yes (Rollout replaces Deployment) | Yes (wraps existing Deployment) | No (separate platform) |
| **AnalysisTemplates** | Built-in, Prometheus-native | Built-in (webhook-based) | Pipeline stages |
| **Istio integration** | Native (trafficRouting.istio) | Native | Plugin-based |
| **Operational complexity** | Low (single controller pod) | Low (single controller pod) | Very high (multiple microservices, Redis, Halyard) |
| **Rollback mechanism** | abort + undo (instant) | rollback to primary | Pipeline re-execution |
| **Monthly cost** | $0 (open source) | $0 (open source) | $0 (open source, but high ops cost) |

Argo Rollouts won because of its **AnalysisTemplate** design. I can define exactly what queries to run against Prometheus, how often to run them, how many failures to tolerate before aborting, and the success/failure conditions -- all declaratively in YAML. The AnalysisTemplate for this project runs three checks every 30 seconds across 4 measurements:

```yaml
# From k8s/app/analysis-template.yaml
- name: success-rate
  successCondition: "result[0] >= 0.99"   # 99% of requests must succeed
- name: latency-p99
  successCondition: "result[0] <= 1.0"    # P99 must stay under 1 second
- name: error-rate
  failureCondition: "result[0] >= 0.01"   # Error rate must stay under 1%
```

With `failureLimit: 1`, the canary is aborted after a single failed measurement. This means a regression is detected and rolled back within approximately 60-90 seconds -- compared to the 4 minutes it historically took humans to notice an error spike.

Flagger is a solid alternative but wraps existing Deployments rather than replacing them. I found the Rollout CRD approach cleaner because the deployment strategy is defined in the same resource as the pod template, making it easier to review in pull requests and understand the full deployment lifecycle from a single file.

Spinnaker was never seriously considered for this exercise. It is a multi-service platform that would take longer to set up than the entire exercise allows, and its operational overhead is disproportionate for a single-service deployment.

### Monitoring Stack: kube-prometheus-stack (Prometheus + Grafana + AlertManager)

| | kube-prometheus-stack (chosen) | Datadog | New Relic |
|---|---|---|---|
| **Deployment** | Helm chart, self-hosted | SaaS agent | SaaS agent |
| **Prometheus-native** | Yes (it IS Prometheus) | PromQL adapter (not native) | NRQL (different query language) |
| **Cost at 3 hosts** | $0 | ~$69/host/mo = $207/mo | ~$0.35/GB ingested, ~$150/mo |
| **AnalysisTemplate integration** | Direct PromQL queries | Requires Datadog provider plugin | Requires custom webhook |
| **Grafana dashboards** | Included | Datadog Dashboards (proprietary) | New Relic Dashboards (proprietary) |
| **Alert routing** | AlertManager (PagerDuty, Slack, webhooks) | Built-in | Built-in |
| **Retention** | Configurable (local storage) | 15 months (plan-dependent) | 8 days default |

The choice was straightforward: kube-prometheus-stack gives me Prometheus, Grafana, and AlertManager in a single Helm install, and Argo Rollouts speaks native PromQL to Prometheus. Using Datadog or New Relic would require either a custom webhook provider in the AnalysisTemplate (more moving parts) or a PromQL compatibility layer (more latency, less reliability for the one query that determines whether a canary gets promoted or aborted).

The cost difference is also stark. For a production setup with 3 worker nodes, Datadog would add ~$207/month just for infrastructure monitoring. Prometheus is free. For this exercise, that decision is obvious. In production, there is a legitimate argument for managed monitoring (less operational burden, better out-of-box dashboards, integrations), but the AnalysisTemplate integration with native Prometheus was the deciding factor.

### Secrets Management: External Secrets Operator + LocalStack

| | ESO + LocalStack/AWS SM (chosen) | SealedSecrets | HashiCorp Vault |
|---|---|---|---|
| **Rotation support** | Yes (refreshInterval: 1h) | No (re-seal required) | Yes (dynamic secrets) |
| **Centralized management** | Yes (all secrets in AWS SM) | No (per-cluster encrypted secrets in Git) | Yes (central Vault server) |
| **Audit trail** | CloudTrail (in production) | Git history only | Vault audit log |
| **Operational complexity** | Low (ESO controller + external store) | Very low (just a controller) | High (HA cluster, unsealing, token management) |
| **Production path** | Direct (swap LocalStack URL for AWS SM URL) | Requires migration | Direct |
| **Monthly cost** | ~$0.40/secret/mo (AWS SM) | $0 | $0 (open source) or $$$ (Enterprise) |

I chose ESO because it establishes the **exact workflow** that would run in production. The ExternalSecret resource points at a ClusterSecretStore, which points at a secrets provider. Locally, that provider is LocalStack simulating AWS Secrets Manager. In production, I change the endpoint URL and authentication method (from static credentials to IRSA) and everything else stays the same. The Kubernetes Secret that the application consumes (`transaction-engine-secrets`) is created identically in both environments.

SealedSecrets was tempting for simplicity -- you encrypt a Secret, commit the ciphertext to Git, and the controller decrypts it in-cluster. But SealedSecrets has no rotation support. When you rotate a database password or API key, you have to re-seal and re-commit. With ESO, I set `refreshInterval: 1h` and the secret is automatically re-synced from AWS Secrets Manager. For PCI-DSS compliance, automated rotation without human intervention is a significant advantage.

Vault was overkill for this scope. Running a production Vault cluster requires its own HA deployment, auto-unsealing configuration, token renewal, and audit logging. That is an infrastructure project on its own. ESO with AWS Secrets Manager gives me 80% of Vault's benefits at 20% of the operational complexity.

### CI/CD Platform: GitHub Actions

| | GitHub Actions (chosen) | GitLab CI | Jenkins |
|---|---|---|---|
| **Native integration** | GitHub (where the repo lives) | GitLab (requires migration) | Standalone (requires server) |
| **Configuration** | YAML in `.github/workflows/` | `.gitlab-ci.yml` | Jenkinsfile or UI |
| **Caching** | GHA cache (Docker layer cache) | Built-in registry cache | Plugin-dependent |
| **Security scanning** | Trivy action + SARIF upload to Security tab | Built-in SAST/DAST | Plugin-dependent |
| **Monthly cost** | Free tier (2,000 min/mo) / ~$0.008/min | Free tier (400 min/mo) | $0 (self-hosted) + server cost |

GitHub Actions was the natural choice because the repository lives on GitHub. The CI pipeline (`.github/workflows/ci.yml`) runs lint, test (with race detection and coverage), build + push to DockerHub, and Trivy security scan -- all triggered on push to master or PR. The deploy pipeline (`.github/workflows/deploy.yml`) is a `workflow_dispatch` with environment selection (staging/production) and image tag input, which maps cleanly to the "single command/button to trigger a deploy" requirement from the exercise.

I pinned all action versions to their full SHA hashes (`actions/checkout@b4ffde65...`) rather than tags (`actions/checkout@v4`) to prevent supply-chain attacks where a tag is re-pointed to a malicious commit. This is a small detail but important for a payment processing pipeline.

### Infrastructure as Code: Terraform

| | Terraform (chosen) | Pulumi | AWS CDK |
|---|---|---|---|
| **Language** | HCL (declarative) | TypeScript/Python/Go | TypeScript/Python |
| **State management** | S3 + DynamoDB (mature, well-understood) | Pulumi Cloud or S3 | CloudFormation (implicit) |
| **Provider ecosystem** | Largest (AWS, GCP, Azure, K8s, Helm, etc.) | Growing | AWS-only |
| **Plan/preview** | `terraform plan` (gold standard) | `pulumi preview` | `cdk diff` |
| **Monthly cost** | $0 (open source) | Free tier / $0.0025/resource/mo | $0 |

Terraform was chosen for the AWS EKS modules (`terraform/modules/eks/`, `terraform/modules/networking/`) because HCL's declarative nature makes infrastructure changes reviewable in pull requests without needing to understand imperative programming logic. The `prevent_destroy` lifecycle rule on the EKS cluster, the KMS key with 30-day deletion window, and the OIDC provider for IRSA are all patterns that are well-documented in HCL and easily audited.

---

## 5. Secrets Management & PCI-DSS Considerations

TransactionEngine handles three secrets that fall under PCI-DSS scope:

1. **DB_CONNECTION_STRING** -- PostgreSQL connection string with credentials for the transactions database.
2. **PROVIDER_API_KEY** -- API key for payment providers (Stripe, Adyen, etc.). Compromise of this key allows unauthorized payment processing.
3. **ENCRYPTION_KEY** -- Used for encrypting cardholder data at rest. Compromise of this key exposes all stored card data.

### Architecture: Local vs Production

```
LOCAL ENVIRONMENT:
  ExternalSecret (k8s/secrets/external-secret.yaml)
       |
       v
  ClusterSecretStore (k8s/secrets/secret-store.yaml)
       |  (endpoint: localstack.secrets.svc:4566)
       v
  LocalStack (simulates AWS Secrets Manager API)
       |
       v
  K8s Secret "transaction-engine-secrets"
       |
       v
  Pod env vars (DB_CONNECTION_STRING, PROVIDER_API_KEY, ENCRYPTION_KEY)


PRODUCTION ENVIRONMENT:
  ExternalSecret (same YAML, different SecretStore)
       |
       v
  ClusterSecretStore (endpoint: AWS SM via IRSA)
       |  (authentication: IRSA role scoped to namespace)
       v
  AWS Secrets Manager (real KMS encryption, CloudTrail audit)
       |
       v
  K8s Secret "transaction-engine-secrets" (envelope-encrypted via EKS KMS key)
       |
       v
  Pod env vars (injected via secretKeyRef)
```

### PCI-DSS Requirements Addressed

| PCI-DSS Requirement | How Addressed | Local | Production |
|---------------------|--------------|-------|------------|
| **Encrypted storage** (Req 3.4) | Secrets encrypted at rest | LocalStack (simulated) | AWS KMS envelope encryption via EKS `encryption_config` |
| **Audit trail** (Req 10.2) | All secret access logged | LocalStack logs (simulated) | CloudTrail records every `GetSecretValue` call with caller identity, timestamp, source IP |
| **Least privilege** (Req 7.1) | Access scoped to minimum necessary | RBAC Role limits SA to `get`/`list` secrets in namespace only | IRSA role scoped to `secretsmanager:GetSecretValue` on `yuno/transaction-engine/*` ARN pattern only |
| **Rotation** (Req 3.6) | Regular key rotation | ESO `refreshInterval: 1h` syncs from LocalStack | ESO `refreshInterval: 1h` syncs from AWS SM; AWS SM supports automatic rotation via Lambda |
| **No hardcoded secrets** (Req 6.5) | Secrets never in code or manifests | `seed-secrets.sh` generates random values with `openssl rand` | Secrets created in AWS SM console or via Terraform (not in Git) |

### What Is NOT Covered in This Exercise

I want to be explicit about what this exercise does NOT implement:

- **HSM key storage:** PCI-DSS Level 1 requires Hardware Security Modules for cryptographic key storage. AWS CloudHSM is ~$1.60/hr (~$1,152/month). I simulate this with LocalStack.
- **Full network segmentation:** Beyond NetworkPolicies (which enforce pod-level isolation), a real PCI environment requires VPC segmentation, private subnets, NACLs, and security groups limiting traffic to specific ports and CIDRs. The Terraform modules define this but they are not deployed in this exercise.
- **Audit log pipeline:** CloudTrail logs exist in production but I have not built the log aggregation pipeline (typically ELK or Datadog Logs) that a PCI auditor would expect.
- **Penetration testing:** PCI-DSS Requirement 11.3 requires annual penetration testing. This exercise has no pen test coverage.
- **Tokenization:** The mock service uses `card_token` but does not implement actual PAN tokenization. A real implementation would use a tokenization service to ensure raw card numbers never reach the TransactionEngine.

---

## 6. What I Got Wrong Initially

I want to be honest about mistakes and pivots during the design process because they reveal more about engineering judgment than the final result does.

### Mistake 1: Nginx Ingress Instead of Istio

My initial instinct was to use Nginx Ingress Controller because it is simpler to set up and I have used it extensively. I got as far as researching Argo Rollouts' Nginx integration before realizing the limitation: Nginx uses annotation-based weighted routing (`nginx.ingress.kubernetes.io/canary-weight: "5"`) which is eventually consistent and less precise at low percentages. When the ingress controller reloads its configuration, there can be a brief period where the weights are not applied. For a payment service where I need deterministic traffic splitting at exactly 5%, Istio's VirtualService with Envoy-based splitting is significantly more reliable. The switch cost me time but was the right call.

### Mistake 2: Kustomize Overlays

I initially designed the Kubernetes manifests with Kustomize overlays (`base/`, `overlays/staging/`, `overlays/production/`) to handle per-environment differences. After laying out the directory structure, I realized the overhead was not justified for this scope: the primary difference between environments is the SecretStore endpoint and the image tag, both of which are better handled by the deploy script and the ClusterSecretStore resource respectively. Plain YAML files organized by concern (`k8s/app/`, `k8s/mesh/`, `k8s/monitoring/`, `k8s/secrets/`, `k8s/base/`) are easier to read, review, and debug. I would reintroduce Kustomize if the project grew to 3+ environments with significant configuration differences.

### Mistake 3: Scope Creep on Epics

I initially planned 12 implementation epics. When I got to the SLI/SLO definitions, I realized they needed their own dedicated epic with proper multi-window burn-rate recording rules and three-tier alerting (page, ticket, warning). A quick recording rule for "success rate > 99%" would have been functionally sufficient for the AnalysisTemplate, but it would have missed the broader observability story: how do you know your error budget is being consumed over days, not just during a single deployment? That led to epic 9 (SLI/SLO definitions) being split from epic 8 (monitoring). Then I added epic 14 for security hardening after reviewing the pod security context and realizing I had not set `seccompProfile: RuntimeDefault` and `readOnlyRootFilesystem: true`. Total: 14 epics.

### Mistake 4: Helm for the App Deployment

I briefly considered using a Helm chart for the TransactionEngine deployment to template the image tag, replica count, and resource limits. I decided against it because the Argo Rollouts `Rollout` CRD replaces the Deployment, and Helm's templating adds a layer of indirection that makes it harder to see exactly what is being deployed. With plain YAML + `kubectl argo rollouts set image`, the deployment process is transparent and reviewable. The `deploy.sh` script is 50 lines of readable bash. A Helm chart for a single service with one set of values would have been over-engineering.

---

## 7. Failure Scenarios & Recovery

I designed for five concrete failure modes, each with automated detection and recovery:

| # | Scenario | Detection Mechanism | Time to Detect | Auto-Recovery | Manual Fallback |
|---|----------|-------------------|---------------|---------------|-----------------|
| 1 | **New version crashes on startup** (e.g., nil pointer in init code) | Startup probe fails: `httpGet /health` with `failureThreshold: 10`, `periodSeconds: 3` = 30s max | ~30 seconds | Argo Rollouts detects pod not becoming Ready, aborts canary | `./scripts/rollback.sh` |
| 2 | **New version returns 5xx errors** (e.g., the concurrency bug we are fixing) | AnalysisTemplate `success-rate` metric: `sum(rate(2xx)) / sum(rate(all)) < 0.99` | ~30-60 seconds (first analysis interval) | Argo Rollouts aborts canary after 1 failed measurement (`failureLimit: 1`) and reverts VirtualService to 100% stable | Check application logs (`kubectl logs -l app=transaction-engine --tail=100`), fix code, redeploy |
| 3 | **New version is slow** (P99 > 1s, e.g., unoptimized query) | AnalysisTemplate `latency-p99` metric: `histogram_quantile(0.99, ...) > 1.0` | ~30-60 seconds | Auto-rollback via Argo Rollouts abort | Profile with pprof, check DB query plans, optimize, redeploy |
| 4 | **Database connection fails during deploy** (e.g., DB maintenance coincides with deploy) | Readiness probe fails (`/health` returns 503 because `ready.Store(false)` in the Go service). Pod is removed from Service endpoints. | ~15 seconds (readinessProbe `periodSeconds: 5`, `failureThreshold: 3`) | Old pods still handle traffic because the canary is never promoted. AnalysisTemplate queries fail (no successful requests from canary), canary is aborted | Fix DB connectivity, redeploy |
| 5 | **Istio control plane (istiod) goes down** | Envoy sidecars continue routing traffic using their last known configuration. Existing connections are unaffected. | N/A (sidecars are resilient to control plane outages) | None needed for existing traffic. New pod scheduling will lack sidecar config until istiod recovers | Restart istiod: `kubectl rollout restart deployment istiod -n istio-system`. Check pilot logs |
| 6 | **Prometheus goes down during canary** | AnalysisTemplate queries return errors instead of metric values | ~30 seconds (first query failure) | Argo Rollouts treats query failures as analysis failures -- canary is **paused** (fail-closed behavior). This is the safe default: if I cannot prove the canary is healthy, do not promote it | Restart Prometheus: `kubectl rollout restart statefulset prometheus-kube-prometheus-stack-prometheus -n monitoring`. Rollout resumes when queries succeed again |
| 7 | **Worker node failure during canary** (e.g., OOM-killed, hardware issue) | Pod evicted, rescheduled by Kubernetes scheduler on a healthy node. `topologySpreadConstraints` with `maxSkew: 1` ensures pods are distributed across all 3 zones | ~30-60 seconds (pod rescheduling + startup) | Pod rescheduled automatically. If the dead node had the canary pod, a new canary pod is scheduled. Stable pods on other nodes continue serving traffic | `kubectl get nodes` to identify failed node. `kubectl drain <node>` if it returns but is unhealthy. `kubectl uncordon` after repair |

### Graceful Shutdown: The Forgotten Edge Case

One failure mode that most deployment solutions ignore is the race condition during pod termination. When Kubernetes sends SIGTERM to a pod, there is a brief window where the pod is still in the Service's endpoint list but has started shutting down. New requests routed to that pod will fail.

I addressed this with two mechanisms:

1. **`preStop` hook with `sleep 5`**: Before the Go process receives SIGTERM, the pod waits 5 seconds. During this time, the kubelet has already sent the "removing endpoints" update to kube-proxy/Envoy. By the time the process starts shutting down, traffic has been drained away.

2. **`terminationGracePeriodSeconds: 60`**: The Go service has a 30-second graceful shutdown timeout (via `srv.Shutdown(shutdownCtx)`). The pod-level grace period is 60 seconds, giving the 5-second preStop hook + 30-second application shutdown ample room to complete without being force-killed.

3. **`maxUnavailable: 0`** in the Rollout strategy: No pod is removed from the stable set until the new pod is Ready. This ensures the stable fleet is never below its minimum replica count during the transition.

---

## 8. SLI/SLO Rationale

### Why These Specific Numbers

**Availability SLO: 99.95%**

At 7,000 req/min, 99.95% availability allows 0.05% errors = ~3.5 failed requests per minute. This might seem generous compared to the industry-standard "five nines" (99.999%), but here is my reasoning:

- 99.999% at 7,000 req/min = 0.07 errors/min allowed. That is less than 1 error per minute. A single DNS hiccup, a single pod restart, a single garbage collection pause would burn through the entire budget. This is unrealistically tight for a Kubernetes-based deployment.
- 99.95% at 7,000 req/min = 3.5 errors/min allowed. This gives enough room for expected infrastructure noise (pod rescheduling, Envoy connection resets, etc.) while still catching real regressions.
- Monthly error budget at 99.95% = 43.8 minutes of equivalent downtime. A bad deployment burning at 14.4x the allowed rate exhausts this in approximately 3 minutes. The tier-1 burn-rate alert fires within 2 minutes. That is tight enough to protect the SLO.

For a real production payment platform, I would target 99.99% (4.3 minutes/month budget) after establishing baseline stability. Starting at 99.95% is honest about the reality of the infrastructure.

**Latency SLO: 99.0% of requests under 1 second (P99 < 1s)**

The exercise states that normal P99 is 890ms. Setting the SLO at P99 < 1s gives 110ms of headroom. This might seem tight, but:

- The mock service simulates latency with a normal distribution: mean 340ms, stddev 150ms, capped at 2000ms. The 99th percentile of `N(340, 150)` is approximately `340 + 2.326 * 150 = 689ms`. So under normal conditions, P99 is well below 1s.
- The 1s threshold catches real regressions: if a code change introduces a slow database query or a synchronous external call, P99 will spike above 1s quickly.
- The 99.0% target (vs. 99.9% or 99.95%) allows 1% of requests to be slow -- approximately 70 slow requests per minute at 7,000 req/min. This accounts for expected tail latency from provider-side delays (payment providers like Adyen and Worldpay have variable response times).

### Burn-Rate Alert Tiers (Google SRE Methodology)

I implemented three-tier burn-rate alerting as described in the Google SRE Workbook, Chapter 5:

| Tier | Burn Rate | Budget Exhaustion | Alert Window | Action |
|------|-----------|-------------------|-------------|--------|
| **Tier 1 (Page)** | 14.4x | ~2 days | 1h (long) AND 5m (short) | PagerDuty -- wake someone up. At 7,000 req/min, 14.4x burn means ~50 errors/min sustained |
| **Tier 2 (Ticket)** | 6x | ~5 days | 6h (long) AND 30m (short) | File a ticket, investigate within the current shift. ~21 errors/min sustained |
| **Tier 3 (Warning)** | 3x | ~10 days | 24h (long) AND 1h (short) | Investigate during business hours. ~10 errors/min sustained |

The dual-window approach prevents alert flapping. The long window detects a sustained problem; the short window confirms it is still happening (not a brief spike that already recovered). Without the short window, a 5-minute spike three hours ago would keep the 6h-window alert firing for the remaining three hours even though the system recovered.

### Error Budget as a Deployment Gate

At 99.95% availability with a 30-day window, the error budget is 43.8 minutes. I defined two additional alerts:

- **NearlyExhausted** (`remaining < 10%`): Less than 4.4 minutes of budget left. Warning to halt non-essential deployments.
- **Exhausted** (`remaining < 0`): SLO breached. Engage leadership. Implement change freeze.

In practice, the error budget should gate deployments: if less than 10% budget remains, the `deploy.sh` script could be extended to check the remaining budget via Prometheus API and refuse to deploy. I did not implement this automation in the exercise, but the recording rule (`transaction_engine:availability_error_budget:remaining`) makes it trivially queryable.

---

## 9. Production vs Exercise

This exercise demonstrates the architecture and patterns for zero-downtime deployment. Here is what I would do differently with unlimited time and a real production environment:

### Service Mesh

- **Exercise:** Istio with sidecar injection (~50MB RAM overhead per pod).
- **Production:** Istio **Ambient mode** (ambient mesh), which moves mTLS and L4 traffic management to a per-node ztunnel DaemonSet, eliminating sidecar overhead entirely. Alternatively, Google Cloud's managed **Anthos Service Mesh** for reduced operational burden.

### Secrets Management

- **Exercise:** ESO pointing at LocalStack with dummy `test`/`test` credentials.
- **Production:** ESO pointing at AWS Secrets Manager with IRSA authentication (no static credentials). AWS KMS with automatic key rotation. CloudTrail logging with real-time alerting on unauthorized `GetSecretValue` calls. For PCI-DSS Level 1: AWS CloudHSM for key storage.

### Monitoring

- **Exercise:** kube-prometheus-stack with local storage, pre-built alerts.
- **Production additions:**
  - **Distributed tracing:** Jaeger or Grafana Tempo integrated with the Istio Envoy sidecars. Traces every transaction from ingress to provider response, enabling latency diagnosis at the span level.
  - **Synthetic monitoring:** Grafana Synthetic Monitoring or AWS CloudWatch Synthetics running `POST /v1/authorize` every 30 seconds from multiple geographic locations to detect availability issues before real users report them.
  - **Real User Monitoring (RUM):** Client-side instrumentation to measure actual merchant-perceived latency (not just server-side P99).
  - **Log aggregation:** Grafana Loki or ELK stack for structured log queries. The Go service already outputs JSON logs with transaction IDs, provider names, and durations -- these need a queryable store.

### CI/CD Pipeline

- **Exercise:** Lint, test, build, scan, deploy (manual trigger).
- **Production additions:**
  - **Staging environment** with full integration tests (including payment provider sandboxes) before production promotion.
  - **Load testing gate:** k6 or Locust running against staging at 2x expected peak (254,000 req/min) to validate the hotfix actually resolves the concurrency timeout under load.
  - **Chaos engineering:** Litmus Chaos or Chaos Monkey running periodic fault injection (pod kill, network partition, CPU stress) to validate resilience.
  - **SBOM generation:** Software Bill of Materials with Syft, uploaded to a dependency-tracking platform like Dependency-Track.
  - **Image signing:** Cosign to sign container images, admission controller to verify signatures before allowing deployment to production.

### Multi-Region

- **Exercise:** Single Kind cluster.
- **Production:** Active-active EKS clusters across 2+ AWS regions (e.g., `us-east-1` and `eu-west-1`). Route 53 latency-based routing or AWS Global Accelerator for geographic traffic distribution. CockroachDB or Aurora Global Database for multi-region data replication. Canary deployments would first target the lowest-traffic region, then promote to all regions sequentially.

### Compliance

- **Exercise:** Security hardening patterns (non-root, readOnlyRootFilesystem, NetworkPolicies).
- **Production:** Full PCI-DSS Level 1 audit controls: dedicated CDE (Cardholder Data Environment) VPC, quarterly ASV scans, annual penetration tests, SOC2 evidence collection pipeline, dedicated audit log retention (7+ years), file integrity monitoring (AIDE/OSSEC), intrusion detection (GuardDuty).

### Cost Optimization

- **Exercise:** N/A (local Kind cluster).
- **Production:** Spot instances for development/staging environments (60-90% savings). Reserved Instances or Savings Plans for production baseline capacity. Karpenter for intelligent autoscaling based on actual pod resource requests. Right-sizing analysis using Kubecost or the VPA recommender. gp3 EBS volumes (already specified in the Terraform module) over gp2 for 20% cost savings.

---

## 10. Cost Analysis

### Production AWS Deployment Estimate

If I were to deploy this exact architecture to AWS, here is the realistic monthly cost:

| Component | AWS Service | Specification | Monthly Cost |
|-----------|------------|---------------|-------------|
| EKS Control Plane | EKS | 1 cluster | $73.00 |
| Worker Nodes | EC2 | 3x t3.medium (On-Demand, 2 vCPU, 4GB RAM) | $100.22 |
| NAT Gateway | VPC | 1 NAT GW + data processing (~50GB/mo) | ~$45.00 |
| Load Balancer | ALB | 1 Application Load Balancer | ~$22.00 |
| Secrets Manager | Secrets Manager | 3 secrets, ~1000 API calls/mo (ESO refreshes) | ~$1.20 |
| KMS | KMS | 1 CMK + ~10,000 requests/mo (EKS envelope encryption) | ~$1.30 |
| CloudWatch | CloudWatch Logs | EKS audit + API logs (~10GB/mo) | ~$30.00 |
| ECR | ECR | 1 repository, ~5GB stored | ~$2.50 |
| S3 | S3 | Terraform state (~1MB) | ~$0.03 |
| **TOTAL** | | | **~$275/month** |

### Cost Comparison: Monitoring Alternatives

| Monitoring Solution | Monthly Cost (3 hosts) | Notes |
|--------------------|----------------------|-------|
| kube-prometheus-stack (this solution) | $0 (self-hosted, included in compute above) | Requires operational expertise |
| Datadog Infrastructure + APM | $69/host x 3 = $207/mo + $31/host APM = $300/mo | Best dashboards, highest cost |
| New Relic | $0.35/GB ingested, ~$150/mo estimate | Good free tier for low volume |
| Grafana Cloud | $0 (free tier up to 10K metrics) | Managed Prometheus/Loki/Tempo |

The self-hosted kube-prometheus-stack saves $150-$300/month compared to commercial alternatives. For a team that already has Kubernetes operational expertise, this is the clear winner. For a team without that expertise, the operational cost of maintaining Prometheus (storage, compaction, retention, high availability) may exceed the subscription cost of Datadog. I chose self-hosted for this exercise because it demonstrates deeper infrastructure knowledge and provides the best AnalysisTemplate integration.

### Cost of Downtime vs Cost of Infrastructure

For perspective on why this infrastructure investment is worth it:

- Monthly infrastructure cost: **~$275**
- Revenue at risk during Black Friday peak (127K txn/min, assuming $50 average transaction, 15 seconds of downtime): **127,000 * 0.25 * $50 * Yuno's_commission_rate**. Even at a conservative 0.5% commission, that is 31,750 transactions * $50 * 0.5% = **$7,937 in lost commission per 15-second outage**.
- One prevented 15-second outage pays for 29 months of infrastructure.

---

## 11. Security: Real vs Theater

I want to be brutally honest about what is real security versus what is security theater in this exercise. Security theater is dangerous because it creates a false sense of safety. I would rather document the gaps than pretend they do not exist.

### Real Security (implemented and enforced)

| Control | Implementation | Why It Matters |
|---------|---------------|----------------|
| **Istio mTLS (STRICT)** | `PeerAuthentication` with `mode: STRICT` | All pod-to-pod communication is encrypted with mutual TLS. An attacker who compromises a pod cannot eavesdrop on traffic between other pods. Certificate rotation is automatic via Istio's Citadel |
| **NetworkPolicies (zero-trust)** | Default deny all + explicit allow rules for Istio, DNS, monitoring | Pods can only communicate with explicitly permitted endpoints. A compromised TransactionEngine pod cannot reach arbitrary cluster services |
| **Non-root containers** | `runAsUser: 65534`, `runAsGroup: 65534`, `runAsNonRoot: true` | Container processes run as `nobody`. Even if an attacker gets code execution inside the container, they cannot escalate to root |
| **Read-only filesystem** | `readOnlyRootFilesystem: true` | Attacker cannot write malicious binaries or modify configuration files inside the container |
| **Drop ALL capabilities** | `capabilities: { drop: ["ALL"] }` | Container has no Linux capabilities. Cannot mount filesystems, change network settings, or perform privileged operations |
| **Seccomp RuntimeDefault** | `seccompProfile: { type: RuntimeDefault }` | Restricts system calls the container can make to the Docker/containerd default set. Blocks dangerous syscalls like `ptrace`, `mount`, `reboot` |
| **RBAC least-privilege** | Role with only `get`/`list` on `secrets` resource | Service account can only read secrets in its own namespace. Cannot create, update, or delete secrets. Cannot access resources in other namespaces |
| **Distroless base image** | `gcr.io/distroless/static-debian12` | No shell, no package manager, no debugging tools in the container image. Attack surface is minimal -- only the Go binary and CA certificates |
| **SA token auto-mount disabled** | `automountServiceAccountToken: false` | Pod does not receive a Kubernetes API token. Even if compromised, the attacker cannot interact with the Kubernetes API server |
| **GHA action pinning** | All GitHub Actions pinned to SHA, not tag | Prevents supply-chain attacks where a malicious actor re-tags a GitHub Action to inject code into the CI pipeline |
| **Trivy security scanning** | Trivy scans every pushed image for CRITICAL and HIGH CVEs | Known vulnerabilities are detected before the image reaches any environment |

### Security Theater (simulated, not production-ready)

| Gap | What The Exercise Does | What Production Needs |
|-----|----------------------|---------------------|
| **LocalStack for secrets** | Dummy AWS SM with `test`/`test` credentials | Real AWS Secrets Manager with KMS-backed encryption, IRSA authentication, CloudTrail audit |
| **No real audit trail** | LocalStack logs secret access but nobody monitors those logs | CloudTrail + real-time alerting on anomalous `GetSecretValue` patterns + 7-year log retention for PCI compliance |
| **No HSM** | Encryption keys stored in LocalStack (unencrypted in memory) | AWS CloudHSM or KMS with HSM-backed key material for PCI-DSS Level 1 |
| **Dummy credentials in seed-secrets.sh** | `openssl rand` generates random values that look realistic but are not real credentials | Secrets created via secure channels (AWS Console, Terraform with encrypted state, or a secrets rotation Lambda) and never visible in scripts |
| **No WAF** | Istio Gateway accepts all traffic | AWS WAF or Cloudflare WAF in front of the ALB with rules for SQLi, XSS, rate limiting, geo-blocking |
| **No penetration testing** | No pen test coverage | Annual penetration test per PCI-DSS Requirement 11.3 |
| **No image signing** | Images pushed to DockerHub without signatures | Cosign image signing + admission controller (Kyverno or OPA Gatekeeper) rejecting unsigned images |
| **No network segmentation beyond NetworkPolicies** | All pods in a single VPC (Kind cluster) | Dedicated CDE VPC with private subnets, NACLs, and security groups. TransactionEngine in a separate subnet from monitoring and control plane |

### Why This Honesty Matters

A real payment platform needs ALL the items in the "Real Security" column AND all the items in the "Production Needs" column. This exercise demonstrates that I understand the full security posture required for PCI-DSS compliance, that I have implemented the patterns that can be implemented locally, and that I am not pretending LocalStack is equivalent to AWS Secrets Manager with CloudHSM. The architecture is designed so that moving from "theater" to "real" requires changing configuration (endpoints, authentication methods), not redesigning the system.

---

## Summary

This infrastructure achieves zero-downtime deployment through the coordinated interaction of five systems:

1. **Argo Rollouts** controls the canary progression (5% -> 25% -> 50% -> 100%) with 60-second analysis pauses at each step.
2. **Istio** provides precise traffic splitting via VirtualService weights and mTLS encryption via PeerAuthentication.
3. **Prometheus** collects metrics every 15 seconds and Argo Rollouts' AnalysisTemplate queries those metrics every 30 seconds to validate canary health.
4. **The Go service** cooperates with the infrastructure via startup/readiness/liveness probes, graceful shutdown, and Prometheus-format metrics exposition.
5. **NetworkPolicies + RBAC + pod security context** enforce defense in depth so that a deployment issue cannot escalate into a security incident.

The total deployment time for a healthy new version is approximately 4 minutes (3 steps x 60s pause + pod startup time). The maximum time to detect and rollback a bad version is approximately 90 seconds (one analysis interval + abort). At 7,000 req/min with a 5% canary, the worst case during the detection window is approximately 525 failed requests (350 req/min * 1.5 min) -- still significantly better than the historical 1,750-5,250 failed requests from the old deployment process, and scoped to only the 5% canary traffic rather than 100%.

For Black Friday, this infrastructure means the hotfix can be deployed with confidence: the canary absorbs a small fraction of traffic, automated analysis validates the fix works under load, and the system rolls back automatically if anything goes wrong. The VP gets zero transaction loss for the other 95% of traffic, and the engineering team gets data-driven confidence that the new version is safe before promoting it to 100%.
