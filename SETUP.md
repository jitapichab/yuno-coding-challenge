# Setup Guide

Step-by-step instructions to set up, deploy, monitor, and tear down the Yuno zero-downtime deployment infrastructure.

---

## 1. Prerequisites

Install the following tools before proceeding. The `setup.sh` script will verify each one is available and print install instructions for any that are missing.

| Tool | Minimum Version | Purpose | Install |
|------|-----------------|---------|---------|
| Docker | >= 24.x | Container runtime for Kind nodes | https://docs.docker.com/get-docker/ |
| kubectl | >= 1.28 | Kubernetes CLI | https://kubernetes.io/docs/tasks/tools/ |
| kind | >= 0.20 | Local multi-node Kubernetes cluster | https://kind.sigs.k8s.io/docs/user/quick-start/#installation |
| Helm | >= 3.12 | Package manager for Prometheus stack, ESO | https://helm.sh/docs/intro/install/ |
| istioctl | >= 1.20 | Istio service mesh installer and CLI | https://istio.io/latest/docs/setup/getting-started/#download |
| kubectl-argo-rollouts | >= 1.6 | Argo Rollouts kubectl plugin | https://argo-rollouts.readthedocs.io/en/stable/installation/#kubectl-plugin-installation |
| AWS CLI | >= 2.x | Required only for `seed-secrets.sh` | https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html |
| Go | >= 1.23 | Required only for mock-service development | https://go.dev/doc/install |
| hey | any | Load testing (optional, curl fallback available) | `go install github.com/rakyll/hey@latest` |

### Verify Prerequisites

```bash
docker --version
kubectl version --client
kind version
helm version --short
istioctl version --remote=false
kubectl argo rollouts version
```

---

## 2. Quick Start (One Command)

```bash
./scripts/setup.sh
```

This single idempotent script performs all of the steps described in Section 3 below. It takes approximately 5-10 minutes on the first run depending on image pull speeds. Running it again is safe -- it skips components that are already installed.

After setup completes, you will see:

```
Cluster 'yuno' is up and running with:
  - Istio (default profile) with sidecar injection on 'transaction-engine'
  - Argo Rollouts in 'argo-rollouts' namespace
  - kube-prometheus-stack in 'monitoring' namespace
  - External Secrets Operator in 'external-secrets' namespace
  - LocalStack (Secrets Manager) in 'secrets' namespace
```

---

## 3. Manual Setup Steps

If you want to understand each component or need to debug a specific step, here is the full manual process:

### Step 1: Create the Kind Cluster

```bash
kind create cluster --config kind-config.yaml
```

This creates a 4-node cluster: 1 control-plane + 3 workers. Each worker is labeled with a different availability zone (`zone-a`, `zone-b`, `zone-c`) to test topology spread constraints.

Verify:

```bash
kubectl cluster-info --context kind-yuno
kubectl get nodes
```

### Step 2: Create Namespaces

```bash
kubectl create namespace transaction-engine
kubectl create namespace monitoring
kubectl create namespace secrets
kubectl create namespace argo-rollouts
kubectl create namespace external-secrets
```

### Step 3: Install Istio

```bash
istioctl install --set profile=default -y
kubectl label namespace transaction-engine istio-injection=enabled --overwrite
```

Verify:

```bash
kubectl get pods -n istio-system
istioctl verify-install
```

### Step 4: Install Argo Rollouts

```bash
kubectl apply -n argo-rollouts \
    -f https://github.com/argoproj/argo-rollouts/releases/latest/download/install.yaml
```

Verify:

```bash
kubectl get pods -n argo-rollouts
```

### Step 5: Add Helm Repositories

```bash
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo add external-secrets https://charts.external-secrets.io
helm repo update
```

### Step 6: Install kube-prometheus-stack

```bash
helm install kube-prometheus-stack prometheus-community/kube-prometheus-stack \
    --namespace monitoring \
    --set grafana.adminPassword=admin \
    --set grafana.service.type=NodePort \
    --set grafana.service.nodePort=30300 \
    --set prometheus.service.type=NodePort \
    --set prometheus.service.nodePort=30900 \
    --set alertmanager.service.type=NodePort \
    --set alertmanager.service.nodePort=30903 \
    --wait --timeout 300s
```

Verify:

```bash
kubectl get pods -n monitoring
```

### Step 7: Install External Secrets Operator

```bash
helm install external-secrets external-secrets/external-secrets \
    --namespace external-secrets \
    --set installCRDs=true \
    --wait --timeout 300s
```

Verify:

```bash
kubectl get pods -n external-secrets
```

### Step 8: Deploy LocalStack

```bash
kubectl apply -f k8s/secrets/localstack-deployment.yaml
```

Wait for it to be ready:

```bash
kubectl rollout status deployment/localstack -n secrets --timeout=120s
```

### Step 9: Apply Secrets Configuration

```bash
kubectl apply -f k8s/secrets/localstack-credentials.yaml
kubectl apply -f k8s/secrets/secret-store.yaml
kubectl apply -f k8s/secrets/external-secret.yaml
```

### Step 10: Seed Secrets into LocalStack

```bash
./scripts/seed-secrets.sh
```

This creates three secrets in LocalStack's Secrets Manager:

- `yuno/transaction-engine/db-connection-string`
- `yuno/transaction-engine/provider-api-key`
- `yuno/transaction-engine/encryption-key`

ESO will sync them to a Kubernetes Secret named `transaction-engine-secrets` in the `transaction-engine` namespace.

### Step 11: Apply Base Kubernetes Manifests

```bash
kubectl apply -f k8s/base/
```

This creates the ServiceAccount, RBAC roles, and namespace configuration.

### Step 12: Apply Monitoring Configuration

```bash
kubectl apply -f k8s/monitoring/service-monitor.yaml
kubectl apply -f k8s/monitoring/prometheus-rules.yaml
kubectl apply -f k8s/monitoring/sli-slo-rules.yaml
kubectl apply -f k8s/monitoring/alertmanager-config.yaml
kubectl apply -f k8s/monitoring/grafana-dashboard-configmap.yaml
```

### Step 13: Apply Istio Mesh Configuration

```bash
kubectl apply -f k8s/mesh/gateway.yaml
kubectl apply -f k8s/mesh/virtual-service.yaml
kubectl apply -f k8s/mesh/destination-rule.yaml
kubectl apply -f k8s/mesh/peer-authentication.yaml
kubectl apply -f k8s/mesh/network-policies.yaml
```

### Step 14: Deploy the Application via Argo Rollouts

```bash
kubectl apply -f k8s/app/services.yaml
kubectl apply -f k8s/app/analysis-template.yaml
kubectl apply -f k8s/app/rollout.yaml
kubectl apply -f k8s/app/hpa.yaml
```

### Step 15: Verify Everything Is Running

```bash
kubectl get pods -n transaction-engine
kubectl get pods -n monitoring
kubectl get pods -n secrets
kubectl get pods -n argo-rollouts
kubectl get pods -n istio-system
kubectl argo rollouts get rollout transaction-engine -n transaction-engine
```

---

## 4. Triggering a Deployment

### Using the deploy script

```bash
./scripts/deploy.sh jitapichab/transaction-engine:v2.0.0
```

The script will:

1. Validate that `kubectl` and `kubectl-argo-rollouts` are available
2. Show the current rollout state
3. Set the new container image on the Argo Rollout
4. Watch the canary progression in real-time

### Using kubectl directly

```bash
kubectl argo rollouts set image transaction-engine \
    transaction-engine=jitapichab/transaction-engine:v2.0.0 \
    -n transaction-engine
```

### Using GitHub Actions

1. Go to the repository's **Actions** tab
2. Select the **Deploy Pipeline** workflow
3. Click **Run workflow**
4. Enter the image tag (e.g., `v2.0.0`) and select the target environment (`staging` or `production`)
5. For production, the workflow requires manual approval via GitHub Environments

### Watching the rollout

```bash
# Real-time terminal view
kubectl argo rollouts get rollout transaction-engine -n transaction-engine --watch

# Quick status check
kubectl argo rollouts status transaction-engine -n transaction-engine
```

---

## 5. Viewing Dashboards

### Start Port Forwards

```bash
./scripts/port-forward.sh start
```

### Grafana

| | |
|---|---|
| URL | http://localhost:3000 |
| Username | `admin` |
| Password | `admin` |
| Dashboard | Search for "TransactionEngine" or navigate to the pre-provisioned deployment dashboard |

**Key dashboard panels:**

- **Request Rate by Version** -- Compare old vs new version throughput during canary
- **Error Rate by Version** -- Spot regressions in the canary immediately
- **Latency Percentiles** -- P50, P95, P99 broken down by version
- **Active Requests** -- Current in-flight request gauge
- **Canary Weight** -- Visual timeline of traffic shifting
- **Error Budget Remaining** -- Availability and latency budget gauges

### Prometheus

| | |
|---|---|
| URL | http://localhost:9090 |

**Useful queries:**

```promql
# Overall success rate (5m window)
transaction_engine:http_request_success_rate:rate5m

# P99 latency (5m window)
transaction_engine:http_request_duration_p99:rate5m

# Error rate by version
transaction_engine:http_error_rate_per_version:rate5m

# Availability SLI (5m window)
transaction_engine:sli_availability:rate5m

# Availability burn rate (1h window)
transaction_engine:availability_burn_rate:1h

# Error budget remaining
transaction_engine:availability_error_budget:remaining

# Active requests
transaction_engine:active_requests:sum
```

### AlertManager

| | |
|---|---|
| URL | http://localhost:9093 |

View currently firing alerts, silenced alerts, and alert group routing. AlertManager routes alerts by severity:

- **critical** -> PagerDuty receiver (simulated)
- **warning** -> Slack `#payment-alerts` receiver (simulated)

### Stop Port Forwards

```bash
./scripts/port-forward.sh stop
```

---

## 6. Performing a Rollback

### Option A: Automated Rollback (no action required)

During a canary deployment, if the AnalysisTemplate detects any of the following, Argo Rollouts automatically aborts:

- Success rate drops below 99% (measured over a 2-minute window)
- P99 latency exceeds 1 second
- Error rate (5xx) exceeds 1%

The abort process routes 100% of traffic back to the stable version and scales down canary pods within 30 seconds (`abortScaleDownDelaySeconds: 30`).

### Option B: Script-Based Rollback

```bash
./scripts/rollback.sh
```

This script handles all states:

1. If a rollout is currently in progress or paused, it aborts first
2. Then it reverts to the previous stable revision
3. Watches until the rollback completes and all pods are ready

### Option C: Manual kubectl Rollback

```bash
# Step 1: Abort any in-progress rollout
kubectl argo rollouts abort transaction-engine -n transaction-engine

# Step 2: Wait a few seconds for traffic to shift back
sleep 5

# Step 3: Revert to previous version
kubectl argo rollouts undo transaction-engine -n transaction-engine

# Step 4: Verify
kubectl argo rollouts get rollout transaction-engine -n transaction-engine
```

### Option D: Promote (skip remaining canary steps)

If the canary is paused and you want to immediately promote it to 100%:

```bash
kubectl argo rollouts promote transaction-engine -n transaction-engine
```

---

## 7. Troubleshooting

### Pods Stuck in Pending

**Symptoms:** Pods remain in `Pending` state and are not scheduled to any node.

**Diagnosis:**

```bash
kubectl describe pod <pod-name> -n transaction-engine
kubectl get events -n transaction-engine --sort-by='.lastTimestamp'
kubectl describe nodes
```

**Common causes and fixes:**

- **Insufficient resources:** Check node capacity with `kubectl top nodes`. Increase Kind worker count or reduce resource requests in the Rollout spec.
- **Topology spread constraints:** The Rollout requires pods to spread across nodes (`maxSkew: 1`). With 3 replicas and 3 workers, this should work. If a worker is NotReady, the constraint cannot be satisfied.
- **Image pull error:** Verify the image exists: `docker manifest inspect jitapichab/transaction-engine:v2.0.0`

---

### Istio Sidecar Not Injected

**Symptoms:** Pods have only 1/1 containers instead of 2/2. Metrics from the sidecar are missing. VirtualService routing does not work.

**Diagnosis:**

```bash
kubectl get namespace transaction-engine --show-labels
kubectl get pods -n transaction-engine -o jsonpath='{.items[*].spec.containers[*].name}'
```

**Fix:**

```bash
kubectl label namespace transaction-engine istio-injection=enabled --overwrite
# Restart pods to pick up the sidecar
kubectl rollout restart deployment -n transaction-engine
```

---

### Rollout Stuck in Paused or Degraded State

**Symptoms:** `kubectl argo rollouts get rollout transaction-engine -n transaction-engine` shows `Paused` or `Degraded` status.

**Diagnosis:**

```bash
kubectl argo rollouts get rollout transaction-engine -n transaction-engine
kubectl argo rollouts status transaction-engine -n transaction-engine
```

**Fix:**

```bash
# To continue the rollout (promote)
kubectl argo rollouts promote transaction-engine -n transaction-engine

# To abort and rollback
kubectl argo rollouts abort transaction-engine -n transaction-engine
kubectl argo rollouts undo transaction-engine -n transaction-engine
```

---

### Secrets Not Syncing

**Symptoms:** The ExternalSecret shows a status other than `SecretSynced`. Pods fail to start with `CreateContainerConfigError` due to missing Secret.

**Diagnosis:**

```bash
kubectl get externalsecret -n transaction-engine
kubectl describe externalsecret transaction-engine-secrets -n transaction-engine
kubectl get secret transaction-engine-secrets -n transaction-engine
kubectl describe clustersecretstore localstack-secrets-manager
kubectl logs -n external-secrets -l app.kubernetes.io/name=external-secrets
```

**Common causes and fixes:**

- **LocalStack not running:** `kubectl get pods -n secrets` -- if LocalStack pod is not Ready, wait or restart it.
- **Secrets not seeded:** Run `./scripts/seed-secrets.sh` to create the secrets in LocalStack.
- **Wrong credentials:** Check `kubectl get secret localstack-credentials -n secrets -o yaml` -- the access key and secret key should both be `test` (base64 encoded: `dGVzdA==`).
- **ClusterSecretStore misconfigured:** The endpoint must point to `http://localstack.secrets.svc.cluster.local:4566`. Check the SecretStore status.

---

### Grafana Dashboard Shows No Data

**Symptoms:** The TransactionEngine dashboard panels show "No data" or "N/A".

**Diagnosis:**

```bash
# Check that ServiceMonitor exists and is valid
kubectl get servicemonitor -n transaction-engine

# Check that Prometheus is scraping the target
# Open http://localhost:9090/targets and look for transaction-engine

# Check that the application is exposing metrics
curl http://localhost:8080/metrics
```

**Common causes and fixes:**

- **ServiceMonitor not applied:** `kubectl apply -f k8s/monitoring/service-monitor.yaml`
- **ServiceMonitor label mismatch:** The ServiceMonitor must have `release: kube-prometheus-stack` label to be picked up by the Prometheus Operator.
- **No traffic yet:** Some panels require actual request traffic to display data. Run `./scripts/load-test.sh 10 30` to generate some traffic.
- **Dashboard not provisioned:** Apply the ConfigMap: `kubectl apply -f k8s/monitoring/grafana-dashboard-configmap.yaml`

---

### AnalysisTemplate Fails Immediately

**Symptoms:** The rollout aborts right after the first canary step because the analysis fails.

**Diagnosis:**

```bash
kubectl argo rollouts get rollout transaction-engine -n transaction-engine
# Look at the AnalysisRun
kubectl get analysisrun -n transaction-engine -l rollouts-pod-template-hash
kubectl describe analysisrun <name> -n transaction-engine
```

**Common causes and fixes:**

- **No metrics data:** If there is no traffic, the Prometheus query returns no results, which is treated as a failure. Generate traffic with `./scripts/load-test.sh` before deploying.
- **Prometheus unreachable:** The AnalysisTemplate queries `http://kube-prometheus-stack-prometheus.monitoring.svc.cluster.local:9090`. Verify this is accessible from within the cluster.
- **Query returns NaN:** Division by zero when there are no requests. This is expected behavior -- the analysis correctly fails when there is insufficient data to validate.

---

### Kind Cluster Fails to Create

**Symptoms:** `kind create cluster` fails with Docker errors.

**Diagnosis:**

```bash
docker info
docker ps
kind get clusters
```

**Common causes and fixes:**

- **Docker not running:** Start Docker Desktop or the Docker daemon.
- **Insufficient resources:** Kind requires at least 4 GB of RAM for a 4-node cluster. Increase Docker's memory allocation in Docker Desktop settings.
- **Port conflict:** The Kind config maps ports 80 and 443 to the host. If another service is using these ports, stop it or modify `kind-config.yaml`.
- **Cluster already exists:** `kind delete cluster --name yuno` and try again.

---

## 8. Teardown

### Remove the Kind Cluster (removes everything)

```bash
kind delete cluster --name yuno
```

This deletes the entire cluster including all namespaces, pods, services, and persistent data.

### Stop Port Forwards Only

```bash
./scripts/port-forward.sh stop
```

### Verify Cleanup

```bash
kind get clusters
docker ps  # Should show no kind-* containers
```
