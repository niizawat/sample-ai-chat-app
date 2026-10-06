"""Chat agent server for Amazon Bedrock AgentCore Runtime."""

from __future__ import annotations

import os

import uvicorn
from ag_ui.core import RunAgentInput
from ag_ui.encoder import EventEncoder
from ag_ui_strands import StrandsAgent
from fastapi import FastAPI, Request
from fastapi.responses import JSONResponse, StreamingResponse
from strands import Agent
from strands.models import BedrockModel

REGION = os.environ.get("AWS_REGION", os.environ.get("AWS_DEFAULT_REGION", "us-east-1"))
MODEL_ID = os.environ.get("BEDROCK_MODEL_ID", "us.openai.gpt-6.1-sol")
SYSTEM_PROMPT = os.environ.get(
    "SYSTEM_PROMPT",
    "You are a helpful assistant. Reply clearly and concisely in the user's language.",
)

app = FastAPI(title="simple-chat-agent")


def build_strands_agent() -> StrandsAgent:
    model = BedrockModel(model_id=MODEL_ID, region_name=REGION)
    strands_agent = Agent(
        model=model,
        system_prompt=SYSTEM_PROMPT,
    )
    return StrandsAgent(
        agent=strands_agent,
        name="simple_chat_agent",
        description="Sample chat agent on Amazon Bedrock AgentCore Runtime",
    )


@app.post("/invocations")
async def invocations(input_data: dict, request: Request) -> StreamingResponse:
    """Stream agent response events for a single run."""
    accept_header = request.headers.get("accept")
    encoder = EventEncoder(accept=accept_header)
    agui_agent = build_strands_agent()

    async def event_generator():
        run_input = RunAgentInput(**input_data)
        async for event in agui_agent.run(run_input):
            yield encoder.encode(event)

    return StreamingResponse(
        event_generator(),
        media_type=encoder.get_content_type(),
    )


@app.get("/ping")
async def ping() -> JSONResponse:
    return JSONResponse({"status": "Healthy"})


if __name__ == "__main__":
    uvicorn.run(app, host="0.0.0.0", port=8080)
