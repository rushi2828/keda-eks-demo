# KEDA Concepts — Learning Guide

## What is KEDA?

KEDA (Kubernetes Event-Driven Autoscaling) is a CNCF project that extends
Kubernetes' native HPA (Horizontal Pod Autoscaler) to support event-driven
scaling from external systems — like queues, streams, and databases.

---

## Core Resources

### 1. ScaledObject
Binds a Kubernetes workload (Deployment, StatefulSet) to an external scaler trigger.

```
ScaledObject
    │
    ├── scaleTargetRef → points to your Deployment
    ├── minReplicaCount → can be 0 (scale-to-zero)
    ├── maxReplicaCount → upper bound
    ├── pollingInterval → how often to check the trigger
    ├── cooldownPeriod  → wait before scaling to zero
    └── triggers[]      → list of event sources (SQS, Kafka, Redis...)
```

### 2. TriggerAuthentication
Provides credentials/auth config for scalers. In this demo we use
`podIdentity: aws` which means KEDA uses the pod's IRSA role — no secrets!

### 3. ScaledJob
Like ScaledObject but for one-off batch Jobs instead of long-running Deployments.

---

## Scale-to-Zero Flow

```
State: Queue EMPTY
  └── KEDA sets replicas = 0 (after cooldownPeriod)
  └── Your pods are terminated, no compute cost

State: Message ARRIVES
  └── KEDA detects queueLength > 0 during pollingInterval
  └── KEDA sets replicas = 1 (initial scale-up takes ~30s)
  └── As queue grows: replicas = ceil(queueDepth / queueLength)

State: Queue DRAINS
  └── KEDA waits cooldownPeriod seconds
  └── KEDA sets replicas = 0 again
```

---

## SQS Scaler — Parameters

| Parameter | Required | Description |
|---|---|---|
| `queueURL` | Yes | Full SQS queue URL |
| `queueLength` | Yes | Messages per pod (target concurrency) |
| `awsRegion` | Yes | AWS region |
| `identityOwner` | No | `operator` = use KEDA's IAM role |

---

## KEDA vs Native HPA

| Feature | HPA | KEDA |
|---|---|---|
| Scale-to-zero | ❌ (min 1) | ✅ |
| External triggers | ❌ | ✅ (50+ scalers) |
| SQS/Kafka/Redis | ❌ | ✅ |
| CPU/Memory | ✅ | ✅ (via HPA) |
| CRD-based config | ❌ | ✅ |

---

## Key Learnings from This Demo

1. **Scale-to-zero saves cost** — idle consumer pods cost nothing
2. **IRSA > static credentials** — IAM roles per pod, no secret rotation
3. **pollingInterval matters** — 30s means ~30s latency on first scale-up
4. **cooldownPeriod prevents flapping** — don't set too low
5. **queueLength is the knob** — tune this for throughput vs latency
