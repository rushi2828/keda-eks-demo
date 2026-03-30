"""
KEDA Demo — SQS Consumer
Polls SQS and processes messages. KEDA scales this pod based on queue depth.
"""
import json
import os
import time
import logging
import boto3
from botocore.exceptions import ClientError

logging.basicConfig(level=logging.INFO, format="%(asctime)s [CONSUMER] %(message)s")
log = logging.getLogger(__name__)

QUEUE_URL = os.environ["SQS_QUEUE_URL"]
REGION = os.environ.get("AWS_REGION", "us-east-1")
PROCESSING_DELAY = float(os.environ.get("PROCESSING_DELAY", "2"))
POD_NAME = os.environ.get("HOSTNAME", "unknown-pod")


def get_sqs_client():
    return boto3.client("sqs", region_name=REGION)


def process_message(message: dict) -> bool:
    """Simulate work. Replace with real processing logic."""
    body = json.loads(message["Body"])
    job_id = body.get("job_id", "unknown")
    log.info("Processing job %s on pod %s", job_id, POD_NAME)
    time.sleep(PROCESSING_DELAY)  # Simulate processing time
    log.info("Completed job %s", job_id)
    return True


def consume_loop(sqs):
    log.info("Consumer started on pod %s. Polling %s", POD_NAME, QUEUE_URL)

    while True:
        try:
            response = sqs.receive_message(
                QueueUrl=QUEUE_URL,
                MaxNumberOfMessages=10,
                WaitTimeSeconds=20,       # Long polling — reduces API calls
                VisibilityTimeout=60,
            )

            messages = response.get("Messages", [])
            if not messages:
                log.debug("No messages, waiting...")
                continue

            for msg in messages:
                try:
                    if process_message(msg):
                        sqs.delete_message(
                            QueueUrl=QUEUE_URL,
                            ReceiptHandle=msg["ReceiptHandle"],
                        )
                except Exception as e:
                    log.error("Failed to process message: %s", e)

        except ClientError as e:
            log.error("SQS error: %s — retrying in 5s", e)
            time.sleep(5)


def main():
    sqs = get_sqs_client()
    consume_loop(sqs)


if __name__ == "__main__":
    main()
