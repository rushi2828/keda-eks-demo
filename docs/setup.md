# Setup Guide

## Step-by-Step Cluster Setup

### 1. Export environment variables
```bash
export AWS_REGION=us-east-1
export AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
export CLUSTER_NAME=keda-demo-cluster
```

### 2. Create EKS cluster
```bash
./scripts/setup-cluster.sh
# Takes ~15 minutes
```

### 3. Verify cluster
```bash
kubectl get nodes
# Should see 2 nodes in Ready state
```

### 4. Install KEDA
```bash
./scripts/install-keda.sh
kubectl get pods -n keda
# keda-operator and keda-metrics-apiserver should be Running
```

### 5. Create SQS + IRSA
```bash
./scripts/create-sqs.sh
# Note the SQS_QUEUE_URL output
export SQS_QUEUE_URL=<output from above>
```

### 6. Update ConfigMap
Edit `manifests/app/consumer-deployment.yaml` and replace `ACCOUNT_ID`
with your actual AWS Account ID.

Also update `manifests/keda/scaledobject.yaml` queue URL.

### 7. Deploy everything
```bash
kubectl apply -f manifests/app/namespace.yaml
kubectl apply -f manifests/keda/
kubectl apply -f manifests/app/
```

### 8. Verify KEDA is watching
```bash
kubectl get scaledobject -n keda-demo
# STATUS should be "True" under READY column

kubectl describe scaledobject consumer-scaledobject -n keda-demo
```

### 9. Run the demo
```bash
# Should see 0 consumer pods (scaled to zero)
kubectl get pods -n keda-demo

# Send load
./scripts/demo-load.sh 50

# Watch pods appear!
kubectl get pods -n keda-demo -w
```

## Troubleshooting

**KEDA not scaling up?**
- Check TriggerAuthentication: `kubectl describe triggerauth -n keda-demo`
- Check KEDA operator logs: `kubectl logs -n keda -l app=keda-operator`
- Verify IRSA: `kubectl describe sa keda-consumer-sa -n keda-demo`

**Pods not connecting to SQS?**
- Check IAM policy is attached to the service account role
- Verify queue URL in ConfigMap matches actual SQS URL
