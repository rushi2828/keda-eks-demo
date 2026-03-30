"""
KEDA Demo — SQS Producer
Sends messages to SQS at a configurable rate to trigger KEDA autoscaling.
"""
import json
import os
import time
import uuid
import logging
from datetime import datetime
import boto3
from botocore.exceptions import ClientError

logging.basicConfig(level=logging.INFO, format="%(asctime)s [PRODUCER] %(message)s")
log = logging.getLogger(__name__)

QUEUE_URL = os.environ["SQS_QUEUE_URL"]
REGION = os.environ.get("AWS_REGION", "us-east-1")
MESSAGES_PER_MINUTE = int(os.environ.get("MESSAGES_PER_MINUTE", "30"))


def get_sqs_client():
    return boto3.client("sqs", region_name=REGION)


def send_message(sqs, job_id: int) -> bool:
    payload = {
        "job_id": str(uuid.uuid4()),
        "sequence": job_id,
        "timestamp": datetime.utcnow().isoformat(),
        "task": f"process-item-{job_id}",
        "metadata": {"producer_host": os.environ.get("HOSTNAME", "unknown")},
    }
    try:
        sqs.send_message(
            QueueUrl=QUEUE_URL,
            MessageBody=json.dumps(payload),
            MessageGroupId="demo",  # for FIFO queues; ignored for standard
        )
        return True
    except ClientError as e:
        log.error("Failed to send message: %s", e)
        return False


def main():
    sqs = get_sqs_client()
    interval = 60 / MESSAGES_PER_MINUTE
    count = 0

    log.info("Starting producer: %d msg/min → %s", MESSAGES_PER_MINUTE, QUEUE_URL)

    while True:
        count += 1
        if send_message(sqs, count):
            log.info("Sent message #%d", count)
        time.sleep(interval)


if __name__ == "__main__":
    main()
