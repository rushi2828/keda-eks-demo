#!/usr/bin/env bash
# ============================================================
# demo-load.sh — Send messages to SQS to trigger KEDA scaling
# ============================================================
set -euo pipefail

QUEUE_URL="${SQS_QUEUE_URL:?Set SQS_QUEUE_URL env variable}"
MESSAGES="${1:-50}"
DELAY="${2:-0}"

echo "📨 Sending $MESSAGES messages to: $QUEUE_URL"
echo "   Watch pods scale: kubectl get pods -n keda-demo -w"
echo ""

for i in $(seq 1 "$MESSAGES"); do
  aws sqs send-message \
    --queue-url "$QUEUE_URL" \
    --message-body "{\"job_id\": \"$i\", \"payload\": \"task-$(date +%s)-$i\", \"delay_seconds\": $DELAY}" \
    --output text > /dev/null
  
  if (( i % 10 == 0 )); then
    DEPTH=$(aws sqs get-queue-attributes \
      --queue-url "$QUEUE_URL" \
      --attribute-names ApproximateNumberOfMessages \
      --query 'Attributes.ApproximateNumberOfMessages' --output text)
    echo "  Sent $i/$MESSAGES messages | Queue depth: $DEPTH"
  fi
done

echo ""
echo "✅ Done! KEDA should start scaling consumers within ~30 seconds."
echo "   Run: kubectl get pods -n keda-demo"
