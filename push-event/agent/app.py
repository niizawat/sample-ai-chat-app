"""Chat agent that can start a conversation from a cloud push event."""

from __future__ import annotations

import base64
import json
import os
import uuid
from collections.abc import AsyncIterator
from typing import Any

import boto3
import uvicorn
from ag_ui.core import (
    RunAgentInput,
    RunFinishedEvent,
    RunStartedEvent,
    TextMessageContentEvent,
    TextMessageEndEvent,
    TextMessageStartEvent,
    UserMessage,
)
from ag_ui.encoder import EventEncoder
from ag_ui_strands import StrandsAgent
from botocore.config import Config as BotocoreConfig
from fastapi import FastAPI, Request
from fastapi.responses import JSONResponse, StreamingResponse
from strands import Agent
from strands.models import BedrockModel

REGION = os.environ.get("AWS_REGION", os.environ.get("AWS_DEFAULT_REGION", "us-east-1"))
MODEL_ID = os.environ.get("BEDROCK_MODEL_ID", "us.openai.gpt-6-luna")
EVENTS_TABLE = os.environ.get("EVENTS_TABLE", "")
MAX_TOKENS = int(os.environ.get("BEDROCK_MAX_TOKENS", "1024"))
BEDROCK_READ_TIMEOUT = int(os.environ.get("BEDROCK_READ_TIMEOUT", "120"))
SYSTEM_PROMPT = os.environ.get(
    "SYSTEM_PROMPT",
    "You are a helpful assistant. Reply clearly and concisely in the user's language. "
    "Keep replies short (a few sentences) unless the user asks for detail.",
)

AGENT_BUILD_ID = os.environ.get("AGENT_BUILD_ID", "prebuilt-event-luna")

app = FastAPI(title="push-event-chat-agent")
dynamodb = boto3.resource("dynamodb", region_name=REGION)


@app.on_event("startup")
async def log_startup() -> None:
    print(
        f"push-event agent start build_id={AGENT_BUILD_ID} "
        f"model={MODEL_ID} max_tokens={MAX_TOKENS} read_timeout={BEDROCK_READ_TIMEOUT}"
    )


def build_strands_agent() -> StrandsAgent:
    # OpenAI models on Bedrock reject inferenceConfig.temperature — do not set it.
    model = BedrockModel(
        model_id=MODEL_ID,
        region_name=REGION,
        max_tokens=MAX_TOKENS,
        boto_client_config=BotocoreConfig(
            read_timeout=BEDROCK_READ_TIMEOUT,
            connect_timeout=10,
            retries={"max_attempts": 2, "mode": "standard"},
        ),
    )
    strands_agent = Agent(
        model=model,
        system_prompt=SYSTEM_PROMPT,
    )
    return StrandsAgent(
        agent=strands_agent,
        name="push_event_chat_agent",
        description="Sample chat agent that can open with a cloud push event",
    )


def _b64url_decode(segment: str) -> bytes:
    padding = "=" * (-len(segment) % 4)
    return base64.urlsafe_b64decode(segment + padding)


def username_from_authorization(authorization: str | None) -> str | None:
    """Read username from a Runtime-verified Bearer JWT without re-verifying."""
    if not authorization:
        return None
    token = authorization.removeprefix("Bearer ").strip()
    parts = token.split(".")
    if len(parts) < 2:
        return None
    try:
        payload = json.loads(_b64url_decode(parts[1]).decode("utf-8"))
    except (ValueError, UnicodeDecodeError, json.JSONDecodeError):
        return None
    username = payload.get("username") or payload.get("cognito:username")
    return username if isinstance(username, str) and username else None


def _events_table():
    if not EVENTS_TABLE:
        raise RuntimeError("EVENTS_TABLE is not configured")
    return dynamodb.Table(EVENTS_TABLE)


def fetch_event(username: str, event_id: str) -> dict[str, Any] | None:
    response = _events_table().get_item(
        Key={"username": username, "eventId": event_id},
    )
    item = response.get("Item")
    return item if isinstance(item, dict) else None


def fetch_latest_pending(username: str) -> dict[str, Any] | None:
    response = _events_table().query(
        KeyConditionExpression="username = :username",
        ExpressionAttributeValues={":username": username},
    )
    items = response.get("Items") or []
    pending = [item for item in items if item.get("status") == "pending"]
    if not pending:
        return None
    pending.sort(key=lambda item: str(item.get("createdAt") or ""), reverse=True)
    return pending[0]


def mark_delivered(username: str, event_id: str) -> None:
    _events_table().update_item(
        Key={"username": username, "eventId": event_id},
        UpdateExpression="SET #status = :delivered",
        ExpressionAttributeNames={"#status": "status"},
        ExpressionAttributeValues={":delivered": "delivered"},
    )


def resolve_event(
    input_data: dict[str, Any],
    username: str | None,
) -> tuple[bool, dict[str, Any] | None]:
    """Return (event_driven, event_item_or_none)."""
    if not username or not EVENTS_TABLE:
        return False, None

    forwarded = input_data.get("forwardedProps") or {}
    if not isinstance(forwarded, dict):
        forwarded = {}

    event_id = forwarded.get("eventId")
    pull_pending = str(forwarded.get("pullPending") or "").lower() in {
        "1",
        "true",
        "yes",
    }
    event_driven = bool((isinstance(event_id, str) and event_id) or pull_pending)
    if not event_driven:
        return False, None

    if isinstance(event_id, str) and event_id:
        return True, fetch_event(username, event_id)
    return True, fetch_latest_pending(username)


def assistant_message_from_event(event: dict[str, Any]) -> str:
    stored = event.get("assistantMessage")
    if isinstance(stored, str) and stored.strip():
        return stored.strip()
    title = str(event.get("title") or "").strip()
    body = str(event.get("body") or "").strip()
    if body:
        if title and title not in body:
            return f"「{title}」\n{body}\n必要であれば、準備や確認事項の整理をお手伝いします。"
        return f"{body}\n必要であれば、準備や確認事項の整理をお手伝いします。"
    return "イベント内容を取得できませんでした。通知を再度開くか、サインインし直してください。"


async def stream_prebuilt_assistant_message(
    encoder: EventEncoder,
    thread_id: str,
    run_id: str,
    text: str,
) -> AsyncIterator[str]:
    message_id = f"event-msg-{uuid.uuid4()}"
    events = [
        RunStartedEvent(type="RUN_STARTED", thread_id=thread_id, run_id=run_id),
        TextMessageStartEvent(
            type="TEXT_MESSAGE_START",
            message_id=message_id,
            role="assistant",
        ),
        TextMessageContentEvent(
            type="TEXT_MESSAGE_CONTENT",
            message_id=message_id,
            delta=text,
        ),
        TextMessageEndEvent(type="TEXT_MESSAGE_END", message_id=message_id),
        RunFinishedEvent(type="RUN_FINISHED", thread_id=thread_id, run_id=run_id),
    ]
    for event in events:
        yield encoder.encode(event)


def prepare_llm_run_input(
    input_data: dict[str, Any],
    username: str | None,
    event_driven: bool,
    event: dict[str, Any] | None,
) -> RunAgentInput:
    run_input = RunAgentInput(**input_data)
    if not event_driven:
        return run_input

    # Event-driven fallback path (no prebuilt message): keep Bedrock valid.
    run_input.messages = [
        UserMessage(
            id=f"event-missing-{uuid.uuid4()}",
            content=(
                "指定されたクラウドイベントを取得できませんでした。"
                "利用者に、通知の再送やアプリの再起動を案内する短い日本語メッセージを返してください。"
            ),
        )
    ]
    _ = username
    _ = event
    return run_input


@app.post("/invocations")
async def invocations(input_data: dict, request: Request) -> StreamingResponse:
    """Stream agent response events for a single run."""
    accept_header = request.headers.get("accept")
    encoder = EventEncoder(accept=accept_header)
    username = username_from_authorization(request.headers.get("authorization"))

    async def event_generator():
        event_driven, event = resolve_event(input_data, username)
        print(
            f"invocation build_id={AGENT_BUILD_ID} username={username!r} "
            f"event_driven={event_driven} has_event={bool(event)} "
            f"has_prebuilt={bool(event and event.get('assistantMessage'))}"
        )

        if event_driven and event:
            text = assistant_message_from_event(event)
            resolved_id = event.get("eventId")
            if event.get("status") == "pending" and isinstance(resolved_id, str):
                mark_delivered(username or "", resolved_id)
            thread_id = str(input_data.get("threadId") or uuid.uuid4())
            run_id = str(input_data.get("runId") or uuid.uuid4())
            print(f"prebuilt_reply eventId={resolved_id!r} chars={len(text)}")
            async for chunk in stream_prebuilt_assistant_message(
                encoder, thread_id, run_id, text
            ):
                yield chunk
            return

        if event_driven and not event:
            run_input = prepare_llm_run_input(input_data, username, True, None)
            agui_agent = build_strands_agent()
            async for event_item in agui_agent.run(run_input):
                yield encoder.encode(event_item)
            return

        # Normal chat: GPT-6 Luna via Strands.
        run_input = RunAgentInput(**input_data)
        agui_agent = build_strands_agent()
        async for event_item in agui_agent.run(run_input):
            yield encoder.encode(event_item)

    return StreamingResponse(
        event_generator(),
        media_type=encoder.get_content_type(),
    )


@app.get("/ping")
async def ping() -> JSONResponse:
    return JSONResponse({"status": "Healthy"})


if __name__ == "__main__":
    uvicorn.run(app, host="0.0.0.0", port=8080)
