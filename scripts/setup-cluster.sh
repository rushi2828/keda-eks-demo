#!/usr/bin/env bash
# ============================================================
# setup-cluster.sh — Create EKS cluster for KEDA demo
# ============================================================
set -euo pipefail

CLUSTER_NAME="${CLUSTER_NAME:-keda-demo-cluster}"
REGION="${AWS_REGION:-us-east-1}"
K8S_VERSION="1.29"
NODE_TYPE="t3.medium"
NODE_COUNT=2

echo "🚀 Creating EKS cluster: $CLUSTER_NAME in $REGION"

cat <<EKSCONFIG | eksctl create cluster -f -
apiVersion: eksctl.io/v1alpha5
kind: ClusterConfig

metadata:
  name: ${CLUSTER_NAME}
  region: ${REGION}
  version: "${K8S_VERSION}"

iam:
  withOIDC: true   # Required for IRSA

managedNodeGroups:
  - name: ng-keda-demo
    instanceType: ${NODE_TYPE}
    desiredCapacity: ${NODE_COUNT}
    minSize: 1
    maxSize: 5
    labels:
      role: worker
    tags:
      project: keda-demo
EKSCONFIG

echo "✅ Cluster created. Updating kubeconfig..."
aws eks update-kubeconfig --name "$CLUSTER_NAME" --region "$REGION"
echo "✅ kubeconfig updated. Run: kubectl get nodes"
