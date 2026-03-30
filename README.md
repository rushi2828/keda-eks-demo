# 🚀 KEDA on EKS — Autoscaling Demo

> **Event-driven autoscaling on Amazon EKS using KEDA (Kubernetes Event-Driven Autoscaling)**  
> A hands-on demonstration project showcasing queue-based workload scaling with Amazon SQS.

---

## 📐 Architecture Overview

```
┌─────────────────────────────────────────────────────────────────┐
│                        Amazon EKS Cluster                       │
│                                                                 │
│  ┌──────────────┐    ┌──────────────────────────────────────┐  │
│  │   Producer   │───▶│           Amazon SQS Queue           │  │
│  │     Pod      │    └──────────────┬───────────────────────┘  │
│  └──────────────┘                   │                          │
│                           ScaledObject watches queue depth      │
│  ┌──────────────┐    ┌──────────────▼───────────────────────┐  │
│  │    KEDA      │───▶│         Consumer Deployment           │  │
│  │  Operator    │    │  (scales 0 ──▶ N based on queue depth)│  │
│  └──────────────┘    └──────────────────────────────────────┘  │
│                                                                 │
│  ┌──────────────────────────────────────────────────────────┐  │
│  │           Prometheus + Grafana  (Monitoring)             │  │
│  └──────────────────────────────────────────────────────────┘  │
└─────────────────────────────────────────────────────────────────┘
```

## 🎯 What This Demo Showcases

| Feature | Description |
|---|---|
| **Scale-to-Zero** | Consumer pods scale down to 0 when queue is empty |
| **Event-Driven Scaling** | Pods scale up automatically as SQS messages arrive |
| **KEDA ScaledObject** | Declarative autoscaling tied to SQS queue depth |
| **IRSA Integration** | IAM Roles for Service Accounts (no static credentials) |
| **Observability** | Prometheus metrics + Grafana dashboards |

---

## 📁 Project Structure

```
keda-eks-demo/
├── .github/workflows/
│   ├── ci.yml               # Lint, test, build Docker images
│   └── deploy.yml           # Deploy to EKS on merge to main
├── docs/
│   ├── architecture.md      # Architecture decisions
│   ├── setup.md             # Cluster setup guide
│   └── keda-concepts.md     # KEDA concepts explained
├── manifests/
│   ├── app/                 # App deployments + namespace
│   ├── keda/                # ScaledObject + TriggerAuthentication
│   └── monitoring/          # ServiceMonitor + Grafana dashboard
├── scripts/                 # Bootstrap and demo scripts
├── src/
│   ├── producer/            # SQS message producer (Python)
│   └── consumer/            # SQS message consumer (Python)
└── README.md
```

---

## ⚡ Quick Start

### Prerequisites
```bash
aws --version     # AWS CLI v2+
eksctl version    # >= 0.150
kubectl version   # >= 1.27
helm version      # >= 3.12
```

### 1 — Create EKS Cluster
```bash
./scripts/setup-cluster.sh
```

### 2 — Install KEDA
```bash
./scripts/install-keda.sh
```

### 3 — Set Up SQS + IAM
```bash
export AWS_REGION=us-east-1
./scripts/create-sqs.sh
```

### 4 — Deploy the App
```bash
kubectl apply -f manifests/app/namespace.yaml
kubectl apply -f manifests/keda/
kubectl apply -f manifests/app/
```

### 5 — Watch the Magic ✨
```bash
# Watch pods scale
watch kubectl get pods -n keda-demo

# Send 100 messages
./scripts/demo-load.sh --messages 100
```

---

## 🔑 KEDA ScaledObject (Core Config)

```yaml
apiVersion: keda.sh/v1alpha1
kind: ScaledObject
metadata:
  name: consumer-scaledobject
spec:
  scaleTargetRef:
    name: consumer
  minReplicaCount: 0       # Scale-to-zero enabled!
  maxReplicaCount: 20
  triggers:
    - type: aws-sqs-queue
      metadata:
        queueURL: https://sqs.us-east-1.amazonaws.com/ACCOUNT/keda-demo-queue
        queueLength: "5"   # 1 pod per 5 messages in queue
      authenticationRef:
        name: keda-trigger-auth-aws
```

---

## 📚 References
- [KEDA Docs](https://keda.sh/docs/) · [SQS Scaler](https://keda.sh/docs/scalers/aws-sqs/) · [EKS Best Practices](https://aws.github.io/aws-eks-best-practices/)
