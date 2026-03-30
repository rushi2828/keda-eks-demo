# KEDA on EKS — Complete Step-by-Step Runbook

> **Every step below includes a "Why this step?" explanation.**  
> This is designed to teach, not just execute. Read the *why* before running the *what*.

---

## Prerequisites Check

### Why this step?
Before anything runs on your machine, you need four CLI tools. Each serves a distinct role:
- `aws` — authenticates to AWS and creates SQS, IAM resources
- `eksctl` — abstracts the complexity of creating an EKS cluster (CloudFormation, VPC, OIDC, node groups) into a single command
- `kubectl` — the universal Kubernetes API client; used for everything once the cluster exists
- `helm` — Kubernetes package manager; installs pre-packaged apps like KEDA and Prometheus with a single command

```bash
aws --version          # Need v2+ (v1 is deprecated)
eksctl version         # Need >= 0.150 (older versions miss --with-oidc flag)
kubectl version        # Need >= 1.27 (matches EKS 1.29 cluster)
helm version           # Need >= 3.12 (OCI chart support)
docker --version       # Only needed to build images locally
```

---

## Part 1 — Infrastructure Setup

### Step 1: Export Environment Variables

**Why this step?**  
Exporting variables once at the start prevents typos in later commands and keeps the scripts portable. All scripts read from these variables — if you need to target a different region or cluster name, change it here and nowhere else.

```bash
export AWS_REGION=us-east-1
export CLUSTER_NAME=keda-demo-cluster
export AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
export NAMESPACE=keda-demo

echo "Account: $AWS_ACCOUNT_ID | Region: $AWS_REGION | Cluster: $CLUSTER_NAME"
```

---

### Step 2: Create the EKS Cluster

**Why this step?**  
EKS provides a managed Kubernetes control plane — AWS handles etcd, API server upgrades, and control plane HA. We run workers on managed node groups (EC2 instances AWS manages for you).

The `--with-oidc` flag is the most important part here. It enables the **OIDC (OpenID Connect) provider** for the cluster — a prerequisite for IRSA. Without OIDC, pods cannot assume IAM roles, meaning you'd have to embed static AWS credentials in secrets (a security anti-pattern).

```bash
chmod +x scripts/setup-cluster.sh
./scripts/setup-cluster.sh
```

What this script does internally:
```yaml
# eksctl cluster config
apiVersion: eksctl.io/v1alpha5
kind: ClusterConfig
metadata:
  name: keda-demo-cluster
  region: us-east-1
  version: "1.29"
iam:
  withOIDC: true         # ← Enables IRSA
managedNodeGroups:
  - name: ng-keda-demo
    instanceType: t3.medium
    desiredCapacity: 2
    minSize: 1
    maxSize: 5
```

**Expected output:** Two nodes in `Ready` state. Takes ~15 minutes.

```bash
# Verify
kubectl get nodes
# NAME                          STATUS   ROLES    AGE   VERSION
# ip-10-0-1-xx.ec2.internal     Ready    <none>   5m    v1.29.x
# ip-10-0-2-xx.ec2.internal     Ready    <none>   5m    v1.29.x
```

---

### Step 3: Create Namespace

**Why this step?**  
Namespaces provide isolation between workloads. All demo resources live in `keda-demo` so they can be deleted atomically with one command, and RBAC policies can be scoped tightly to this namespace rather than cluster-wide.

```bash
kubectl apply -f manifests/app/namespace.yaml

# Verify
kubectl get namespace keda-demo
```

---

### Step 4: Create the SQS Queue and IAM Role (IRSA)

**Why this step?**  
This step does three things in sequence:

1. **Creates the SQS queue** — the event source that drives KEDA scaling
2. **Creates an IAM policy** — grants least-privilege SQS permissions (`ReceiveMessage`, `DeleteMessage`, `GetQueueAttributes`, `SendMessage`)
3. **Creates an IAM Role linked to a Kubernetes ServiceAccount** via IRSA — this is the secure, credential-free way for pods to call AWS APIs

**Why IRSA over static credentials?**  
Static credentials (access keys in Secrets) create rotation burden, leak risk, and broad permissions. IRSA links a Kubernetes ServiceAccount → OIDC provider → IAM Role. The pod gets a short-lived token injected at runtime by the EKS Pod Identity webhook. No secrets to manage.

```bash
chmod +x scripts/create-sqs.sh
./scripts/create-sqs.sh

# Save the output
export SQS_QUEUE_URL=<printed by script>
```

Verify IRSA is set up correctly:
```bash
kubectl get serviceaccount keda-consumer-sa -n keda-demo -o yaml
# Should show annotation:
# eks.amazonaws.com/role-arn: arn:aws:iam::ACCOUNT_ID:role/KEDADemoSQSRole
```

---

## Part 2 — Install KEDA

### Step 5: Install KEDA via Helm

**Why this step?**  
KEDA is not part of vanilla Kubernetes. Installing it adds three things to your cluster:

1. **keda-operator** — watches `ScaledObject` CRDs and calls the Kubernetes API to adjust `Deployment` replicas
2. **keda-metrics-apiserver** — implements the Kubernetes External Metrics API so HPA can consume KEDA's scaler values
3. **Custom Resource Definitions (CRDs)** — `ScaledObject`, `ScaledJob`, `TriggerAuthentication` — the new Kubernetes resource types KEDA introduces

We enable `prometheus.metricServer.enabled=true` so KEDA exposes its own metrics for Grafana dashboards.

```bash
chmod +x scripts/install-keda.sh
./scripts/install-keda.sh
```

Verify KEDA is healthy:
```bash
kubectl get pods -n keda
# keda-operator-xxx              1/1   Running   ✅
# keda-metrics-apiserver-xxx     1/1   Running   ✅

kubectl get crds | grep keda
# scaledobjects.keda.sh
# scaledjobs.keda.sh
# triggerauthentications.keda.sh
```

---

### Step 6: Apply TriggerAuthentication

**Why this step?**  
Before deploying the `ScaledObject`, KEDA needs to know *how* to authenticate when it calls SQS to check queue depth. The `TriggerAuthentication` resource points KEDA to use the pod's AWS identity (IRSA), not static credentials.

```bash
kubectl apply -f manifests/keda/triggerauthentication.yaml

# Verify
kubectl describe triggerauthentication keda-trigger-auth-aws -n keda-demo
```

---

### Step 7: Update Manifests with Your Account ID

**Why this step?**  
The `ScaledObject` and `ConfigMap` contain placeholder `ACCOUNT_ID` strings referencing the SQS queue URL. You must replace these with your actual AWS account ID before applying, otherwise KEDA cannot find the queue.

```bash
sed -i "s/ACCOUNT_ID/${AWS_ACCOUNT_ID}/g" manifests/keda/scaledobject.yaml
sed -i "s/ACCOUNT_ID/${AWS_ACCOUNT_ID}/g" manifests/app/consumer-deployment.yaml

# Verify replacement worked
grep -n "sqs.amazonaws.com" manifests/keda/scaledobject.yaml
# Should show your real account ID, not "ACCOUNT_ID"
```

---

### Step 8: Apply the ScaledObject

**Why this step?**  
The `ScaledObject` is the heart of this entire demo. It instructs KEDA to:
- **Watch** the SQS queue every 30 seconds (`pollingInterval`)
- **Scale** the `consumer` Deployment based on `ceil(queueDepth / 5)` replicas
- **Scale to zero** when the queue is empty (`minReplicaCount: 0`)
- **Cap** at 20 pods (`maxReplicaCount: 20`)
- **Cool down** for 5 minutes before scaling to zero (`cooldownPeriod: 300`) to avoid flapping

```bash
kubectl apply -f manifests/keda/scaledobject.yaml

# Verify KEDA accepted it (READY column should be True)
kubectl get scaledobject -n keda-demo
# NAME                     SCALETARGETKIND   SCALETARGETNAME   READY   ACTIVE   FALLBACK
# consumer-scaledobject    Deployment        consumer          True    False    Unknown
```

`ACTIVE: False` is correct — it means the queue is empty and KEDA has scaled to zero.

---

## Part 3 — Deploy the Application

### Step 9: Deploy Consumer and Producer

**Why this step?**  
Now that KEDA is watching, we deploy the actual application workloads:

- **Consumer Deployment** — intentionally has *no* `replicas` field in the YAML. KEDA owns this value entirely. If you set `replicas: 1`, Kubernetes and KEDA would fight over the replica count on every reconcile loop.
- **Producer Deployment** — sends messages to SQS at a configurable rate. In a real system this would be your actual workload (e.g., API requests queued from a web server).

```bash
kubectl apply -f manifests/app/consumer-deployment.yaml
kubectl apply -f manifests/app/producer-deployment.yaml

# Consumer should have 0/0 pods (KEDA has not activated it yet)
kubectl get deployment consumer -n keda-demo
# NAME       READY   UP-TO-DATE   AVAILABLE
# consumer   0/0     0            0          ← Correct! Queue is empty.
```

---

## Part 4 — Observability Stack

### Step 10: Install Prometheus + Grafana

**Why this step?**  
Without metrics, autoscaling is a black box. `kube-prometheus-stack` installs:
- **Prometheus** — scrapes metrics every 15s from KEDA, apps, and nodes
- **Grafana** — dashboards that visualize queue depth vs pod count over time
- **Alertmanager** — fires alerts if queue backlog grows beyond capacity or error rate spikes
- **kube-state-metrics** — exposes Deployment replica counts (`kube_deployment_status_replicas`) — essential for plotting "pods created by KEDA" in Grafana
- **node-exporter** — CPU/memory per EC2 node

We configure `serviceMonitorSelectorNilUsesHelmValues: false` so Prometheus picks up ServiceMonitors from *all* namespaces (keda, keda-demo, monitoring), not just the one it's installed in.

```bash
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo update

helm upgrade --install kube-prometheus-stack prometheus-community/kube-prometheus-stack \
  --namespace monitoring \
  --create-namespace \
  --version 57.2.0 \
  --values manifests/monitoring/prometheus-values.yaml \
  --wait --timeout 10m
```

Verify:
```bash
kubectl get pods -n monitoring | grep -E "prometheus|grafana|alertmanager"
```

---

### Step 11: Install Loki + Promtail

**Why this step?**  
Metrics tell you *that* something happened (e.g., error rate spiked). Logs tell you *why*. Loki is a log aggregation system that stores logs in compressed chunks, indexed only by labels — much cheaper than Elasticsearch for Kubernetes log volumes.

**Promtail** is the DaemonSet agent that ships pod logs to Loki. It:
1. Tails `/var/log/pods/` on each node
2. Attaches Kubernetes metadata labels (namespace, pod, app) automatically
3. Parses JSON log lines from our Python apps to extract structured fields (`level`, `job_id`, `message`)

This means in Grafana you can query: `{namespace="keda-demo", app="consumer"} | json | level="ERROR"` — filtered, structured log search in real time.

```bash
helm upgrade --install loki grafana/loki-stack \
  --namespace monitoring \
  --version 2.10.2 \
  --values manifests/monitoring/loki-values.yaml \
  --wait --timeout 5m
```

Verify Promtail is running on every node:
```bash
kubectl get daemonset promtail -n monitoring
# DESIRED should equal number of nodes (e.g., 2)
```

---

### Step 12: Deploy OpenTelemetry Collector

**Why this step?**  
The OTel Collector is the vendor-neutral telemetry pipeline. Rather than having each app talk directly to Prometheus, Loki, and a tracing backend, apps send all telemetry (traces, metrics, logs) to the collector via **OTLP** (OpenTelemetry Protocol) on port 4317.

The collector then:
1. **Enriches** spans with Kubernetes metadata (pod name, node, deployment) via the `k8sattributes` processor
2. **Filters** noise (health check spans) via the `filter` processor
3. **Batches** data before export to reduce network calls
4. **Routes** traces to Tempo and metrics to Prometheus

This architecture decouples your app code from observability backends — swap Tempo for Jaeger without touching any application code.

```bash
kubectl apply -f manifests/monitoring/otel-collector.yaml

kubectl rollout status daemonset/otel-collector -n monitoring --timeout=90s

# Verify it's listening
kubectl port-forward svc/otel-collector 4317:4317 -n monitoring &
# Your apps can now send traces to localhost:4317
```

---

### Step 13: Apply ServiceMonitors, Dashboard, and Alert Rules

**Why this step?**  
- **ServiceMonitors** tell the Prometheus Operator exactly which services to scrape and at what interval. Without them, Prometheus wouldn't know about KEDA's or your app's `/metrics` endpoints.
- **Grafana Dashboard ConfigMap** auto-provisions our pre-built dashboard so it appears in Grafana immediately without manual JSON import.
- **PrometheusRule** creates alerting rules: if the queue backlog exceeds 50 messages while already at max pods, or if consumer error rate exceeds 5%, Alertmanager fires.

```bash
# Or run everything in one go:
./scripts/install-monitoring.sh

# Manual apply if preferred:
kubectl apply -f manifests/monitoring/servicemonitor.yaml
kubectl apply -f manifests/monitoring/alerting-rules.yaml

kubectl create configmap grafana-dashboard-keda \
  --from-file=keda-eks-demo.json=manifests/monitoring/grafana-dashboard-keda.json \
  --namespace monitoring --dry-run=client -o yaml | kubectl apply -f -
```

---

### Step 14: Access Grafana

**Why this step?**  
`kubectl port-forward` tunnels a local port to a service inside the cluster without exposing it via a LoadBalancer. This is the secure way to access internal dashboards during development — no public IP, no ingress controller needed.

```bash
kubectl port-forward svc/kube-prometheus-stack-grafana 3000:80 -n monitoring
```

Open **http://localhost:3000**

- Username: `admin`
- Password: `keda-demo-2024`
- Navigate to: **Dashboards → KEDA Demo → KEDA on EKS — Autoscaling Observability**

You will see four sections:
1. **KEDA Scaling Overview** — queue depth stat, pod count stat, scaler state, throughput
2. **Scaling Timeline** — the key graph: queue depth (orange) vs pod count (green) over time
3. **Application Throughput** — producer send rate vs consumer processed rate vs errors, plus latency percentiles
4. **Live Logs** — Loki-powered log panels for consumer pods and KEDA operator

---

## Part 5 — Run the Demo

### Step 15: Confirm Scale-to-Zero

**Why this step?**  
Before sending load, confirm the baseline state: zero consumer pods. This is the entire value proposition of scale-to-zero — idle workloads cost nothing.

```bash
kubectl get pods -n keda-demo
# No resources found in keda-demo namespace.

kubectl get deployment consumer -n keda-demo
# NAME       READY   UP-TO-DATE   AVAILABLE
# consumer   0/0     0            0
```

In Grafana, the "Consumer Pods" stat panel should show **SCALED TO ZERO** (blue background).

---

### Step 16: Send Load and Watch Scaling

**Why this step?**  
This is the payoff. Sending messages to SQS triggers KEDA to detect `queueDepth > 0` on its next poll (within 30 seconds) and scale the consumer Deployment from 0 to N pods.

Open three terminals:

```bash
# Terminal 1 — watch pods appear
watch -n2 kubectl get pods -n keda-demo

# Terminal 2 — watch scaling events
kubectl get events -n keda-demo --watch

# Terminal 3 — send load
./scripts/demo-load.sh 100
# Sends 100 messages, prints queue depth every 10 messages
```

**What to observe:**
- Messages sent → queue depth rises → KEDA detects it → Consumer pods created
- Formula: `ceil(queueDepth / 5)` = 20 msgs → 4 pods, 50 msgs → 10 pods
- Consumer pods process messages → queue drains → KEDA waits cooldownPeriod → pods removed

In Grafana, the **Scaling Timeline** panel will show the inverted V-shape: queue rises, pods follow up, queue drops, pods follow down.

---

### Step 17: Watch Scale-Down to Zero

**Why this step?**  
After the queue drains, KEDA waits for `cooldownPeriod` (300 seconds by default) before scaling to zero. This prevents flapping if messages arrive sporadically. Watch the cooldown play out:

```bash
# Monitor queue depth
watch -n5 aws sqs get-queue-attributes \
  --queue-url $SQS_QUEUE_URL \
  --attribute-names ApproximateNumberOfMessages \
  --query 'Attributes.ApproximateNumberOfMessages' \
  --output text

# After queue hits 0, wait ~5 minutes, then:
kubectl get pods -n keda-demo
# No resources found — back to zero ✅
```

---

## Part 6 — Validate the Full Stack

### Step 18: Validate Prometheus is Scraping KEDA

**Why this step?**  
A ServiceMonitor only works if Prometheus can actually reach the target. This step confirms the scrape is succeeding before trusting the Grafana numbers.

```bash
kubectl port-forward svc/kube-prometheus-stack-prometheus 9090:9090 -n monitoring &

# Open http://localhost:9090/targets
# Look for: keda/keda-metrics-apiserver — should be UP (green)

# Or via CLI:
curl -s http://localhost:9090/api/v1/query \
  --data-urlencode 'query=keda_scaler_metrics_value' | jq '.data.result'
```

---

### Step 19: Validate Loki is Receiving Logs

**Why this step?**  
Loki's push model means logs only appear if Promtail is running and correctly targeting your pods. This validates the full log pipeline.

```bash
kubectl port-forward svc/loki 3100:3100 -n monitoring &

# Query last 50 consumer log lines
curl -G http://localhost:3100/loki/api/v1/query \
  --data-urlencode 'query={namespace="keda-demo", app="consumer"}' \
  --data-urlencode 'limit=50' | jq '.data.result[].values[][1]'
```

---

### Step 20: Validate OTel Collector

**Why this step?**  
The OTel Collector is a pipeline — if any stage (receiver, processor, exporter) is failing, spans get dropped silently. Checking its own metrics surfaces these issues.

```bash
kubectl port-forward svc/otel-collector 8889:8889 -n monitoring &

curl http://localhost:8889/metrics | grep otelcol_receiver_accepted_spans
# Should show a counter > 0 if your apps are sending traces
```

---

## Cleanup

### Why clean up?
EKS clusters cost ~$0.10/hour for the control plane plus EC2 node costs. An idle 2-node `t3.medium` cluster costs ~$2.40/day. Always delete demo resources when done.

```bash
# Step 1 — Delete app and KEDA resources
kubectl delete -f manifests/app/
kubectl delete -f manifests/keda/

# Step 2 — Uninstall Helm releases
helm uninstall kube-prometheus-stack -n monitoring
helm uninstall loki -n monitoring
helm uninstall keda -n keda

# Step 3 — Delete namespace (removes all remaining resources)
kubectl delete namespace keda-demo monitoring keda

# Step 4 — Delete SQS queue
aws sqs delete-queue --queue-url $SQS_QUEUE_URL

# Step 5 — Delete IAM resources
aws iam delete-policy \
  --policy-arn arn:aws:iam::${AWS_ACCOUNT_ID}:policy/KEDADemoSQSPolicy

# Step 6 — Delete EKS cluster (most expensive, takes ~10 min)
eksctl delete cluster --name $CLUSTER_NAME --region $AWS_REGION

echo "✅ All resources deleted. No ongoing charges."
```

---

## Quick Reference Card

```
KEDA SCALING FORMULA:
  desiredReplicas = ceil(queueDepth / queueLength)
  e.g. 47 messages / queueLength=5 → ceil(9.4) = 10 pods

KEY FILES:
  manifests/keda/scaledobject.yaml          ← Core KEDA config
  manifests/keda/triggerauthentication.yaml ← IRSA auth (no secrets)
  manifests/monitoring/servicemonitor.yaml  ← Prometheus scrape targets
  manifests/monitoring/grafana-dashboard-keda.json ← Dashboard
  manifests/monitoring/otel-collector.yaml  ← Trace pipeline

USEFUL COMMANDS:
  kubectl get scaledobject -n keda-demo     ← KEDA status
  kubectl get events -n keda-demo           ← Scaling events
  kubectl logs -n keda -l app=keda-operator ← KEDA decisions
  kubectl top pods -n keda-demo             ← Resource usage

GRAFANA: localhost:3000 (admin / keda-demo-2024)
  Dashboard → KEDA Demo → KEDA on EKS — Autoscaling Observability

PROMETHEUS: localhost:9090
  Targets → check keda/keda-metrics-apiserver is UP

LOKI QUERY (in Grafana Explore):
  {namespace="keda-demo", app="consumer"} | json | level="ERROR"
```
