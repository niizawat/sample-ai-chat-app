"""Store a pending chat event and publish an FCM push via Amazon SNS."""

from __future__ import annotations

import json
import os
import uuid
from datetime import datetime, timezone
from typing import Any

import boto3
from botocore.exceptions import ClientError

sns = boto3.client("sns")
dynamodb = boto3.resource("dynamodb")

DEVICES_TABLE = os.environ["DEVICES_TABLE"]
EVENTS_TABLE = os.environ["EVENTS_TABLE"]

devices_table = dynamodb.Table(DEVICES_TABLE)
events_table = dynamodb.Table(EVENTS_TABLE)


def _build_assistant_message(title: str, body: str) -> str:
    """Build the first assistant reply without calling an LLM.

    Stored at emit time so the device can render it immediately on connect.
    """
    text = body.strip()
    if title.strip() and title.strip() not in text:
        text = f"「{title.strip()}」\n{text}"
    return (
        f"{text}\n"
        "必要であれば、準備や確認事項の整理をお手伝いします。"
    )


def _build_fcm_message(title: str, event_id: str) -> str:
    notification_title = "エージェント"
    notification_body = title
    gcm_payload = {
        "fcmV1Message": {
            "message": {
                "notification": {
                    "title": notification_title,
                    "body": notification_body,
                },
                "data": {
                    "eventId": event_id,
                },
                "apns": {
                    "payload": {
                        "aps": {
                            "alert": {
                                "title": notification_title,
                                "body": notification_body,
                            },
                            "sound": "default",
                        }
                    }
                },
            }
        }
    }
    return json.dumps(
        {
            "default": notification_body,
            "GCM": json.dumps(gcm_payload, ensure_ascii=False),
        },
        ensure_ascii=False,
    )


def handler(event: dict[str, Any], _context: Any) -> dict[str, Any]:
    username = event.get("username")
    title = event.get("title")
    body = event.get("body")

    if not isinstance(username, str) or not username.strip():
        raise ValueError("username is required")
    if not isinstance(title, str) or not title.strip():
        raise ValueError("title is required")
    if not isinstance(body, str) or not body.strip():
        raise ValueError("body is required")

    username = username.strip()
    title = title.strip()
    body = body.strip()

    device = devices_table.get_item(Key={"username": username}).get("Item")
    if not device or not device.get("endpointArn"):
        raise ValueError(f"No registered device for username={username}")

    event_id = str(uuid.uuid4())
    created_at = datetime.now(timezone.utc).isoformat()
    assistant_message = _build_assistant_message(title, body)
    events_table.put_item(
        Item={
            "username": username,
            "eventId": event_id,
            "title": title,
            "body": body,
            "assistantMessage": assistant_message,
            "status": "pending",
            "createdAt": created_at,
        }
    )

    endpoint_arn = str(device["endpointArn"])
    try:
        publish_result = sns.publish(
            TargetArn=endpoint_arn,
            MessageStructure="json",
            Message=_build_fcm_message(title, event_id),
        )
    except ClientError as exc:
        raise RuntimeError(
            f"SNS publish failed: {exc.response['Error'].get('Message', str(exc))}"
        ) from exc

    return {
        "eventId": event_id,
        "username": username,
        "endpointArn": endpoint_arn,
        "messageId": publish_result.get("MessageId"),
        "status": "pending",
        "assistantMessage": assistant_message,
    }
