#!/usr/bin/env bash
# ============================================================
# create-sqs.sh — Create SQS queue and IAM role with IRSA
# ============================================================
set -euo pipefail

QUEUE_NAME="${QUEUE_NAME:-keda-demo-queue}"
REGION="${AWS_REGION:-us-east-1}"
CLUSTER_NAME="${CLUSTER_NAME:-keda-demo-cluster}"
NAMESPACE="keda-demo"
SA_NAME="keda-consumer-sa"
POLICY_NAME="KEDADemoSQSPolicy"
ROLE_NAME="KEDADemoSQSRole"

ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)

echo "📬 Creating SQS queue: $QUEUE_NAME"
QUEUE_URL=$(aws sqs create-queue \
  --queue-name "$QUEUE_NAME" \
  --attributes VisibilityTimeout=60,MessageRetentionPeriod=86400 \
  --region "$REGION" \
  --query QueueUrl --output text)

QUEUE_ARN=$(aws sqs get-queue-attributes \
  --queue-url "$QUEUE_URL" \
  --attribute-names QueueArn \
  --query 'Attributes.QueueArn' --output text)

echo "✅ Queue created: $QUEUE_URL"
echo "   ARN: $QUEUE_ARN"

echo "🔐 Creating IAM policy..."
aws iam create-policy \
  --policy-name "$POLICY_NAME" \
  --policy-document "{
    \"Version\": \"2012-10-17\",
    \"Statement\": [{
      \"Effect\": \"Allow\",
      \"Action\": [
        \"sqs:ReceiveMessage\",
        \"sqs:DeleteMessage\",
        \"sqs:GetQueueAttributes\",
        \"sqs:GetQueueUrl\",
        \"sqs:SendMessage\"
      ],
      \"Resource\": \"$QUEUE_ARN\"
    }]
  }" || echo "Policy may already exist, continuing..."

echo "🔗 Creating IRSA role..."
eksctl create iamserviceaccount \
  --cluster="$CLUSTER_NAME" \
  --namespace="$NAMESPACE" \
  --name="$SA_NAME" \
  --attach-policy-arn="arn:aws:iam::${ACCOUNT_ID}:policy/${POLICY_NAME}" \
  --override-existing-serviceaccounts \
  --approve

echo "✅ IRSA setup complete!"
echo ""
echo "Export these for use in manifests:"
echo "  export SQS_QUEUE_URL=$QUEUE_URL"
echo "  export SQS_QUEUE_ARN=$QUEUE_ARN"
echo "  export AWS_ACCOUNT_ID=$ACCOUNT_ID"
