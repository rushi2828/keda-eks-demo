#!/usr/bin/env bash
# ============================================================
# install-keda.sh — Install KEDA on EKS via Helm
# ============================================================
set -euo pipefail

KEDA_NAMESPACE="keda"
KEDA_VERSION="2.13.0"

echo "📦 Adding KEDA Helm repo..."
helm repo add kedacore https://kedacore.github.io/charts
helm repo update

echo "🚀 Installing KEDA $KEDA_VERSION into namespace: $KEDA_NAMESPACE"
helm upgrade --install keda kedacore/keda \
  --namespace "$KEDA_NAMESPACE" \
  --create-namespace \
  --version "$KEDA_VERSION" \
  --set prometheus.metricServer.enabled=true \
  --set prometheus.operator.enabled=true \
  --wait

echo "✅ KEDA installed. Verifying..."
kubectl get pods -n "$KEDA_NAMESPACE"
kubectl get crds | grep keda
