"""
LLM Gateway — smart reverse proxy for DGX Spark vLLM cluster.

Routing rules:
  /v1/responses*        → server1 only (Responses API is stateful: previous_response_id
                          references an in-memory store on the server that created the response,
                          so all Responses API traffic must be sticky to one server)
  /v1/chat/completions  → round-robin across server1 + server2
  everything else       → server1 (models list, health, embeddings, etc.)

Configuration via environment variables:
  VLLM_SERVER1_URL   default: http://192.168.200.101:30000
  VLLM_SERVER2_URL   default: http://192.168.200.102:30000
  REQUEST_TIMEOUT    default: 300 (seconds)
  GATEWAY_PORT       default: 8080 (used in log output only)
  LOG_LEVEL          default: INFO
"""

import itertools
import json
import logging
import os
from contextlib import asynccontextmanager
from typing import AsyncIterator

import httpx
from fastapi import FastAPI, Request, Response
from fastapi.responses import StreamingResponse

SERVER1 = os.getenv("VLLM_SERVER1_URL", "http://192.168.200.101:30000")
SERVER2 = os.getenv("VLLM_SERVER2_URL", "http://192.168.200.102:30000")
TIMEOUT = float(os.getenv("REQUEST_TIMEOUT", "300"))

logging.basicConfig(
    level=os.getenv("LOG_LEVEL", "INFO"),
    format="%(asctime)s %(levelname)s %(name)s: %(message)s",
)
log = logging.getLogger("llm-gateway")

_chat_servers = itertools.cycle([SERVER1, SERVER2])
_client: httpx.AsyncClient | None = None

# Headers that must not be forwarded upstream
_STRIP_REQUEST = {"host", "transfer-encoding", "content-length", "connection"}
_STRIP_RESPONSE = {"transfer-encoding", "connection"}


@asynccontextmanager
async def lifespan(app: FastAPI) -> AsyncIterator[None]:
    global _client
    _client = httpx.AsyncClient(timeout=TIMEOUT, follow_redirects=True)
    log.info("LLM Gateway started — server1=%s  server2=%s", SERVER1, SERVER2)
    yield
    await _client.aclose()


app = FastAPI(title="LLM Gateway", lifespan=lifespan)


def _req_headers(request: Request) -> dict[str, str]:
    return {k: v for k, v in request.headers.items() if k.lower() not in _STRIP_REQUEST}


async def _forward(target_url: str, request: Request) -> Response:
    body = await request.body()
    headers = _req_headers(request)

    # Peek at the body to decide whether to stream
    is_stream = False
    if body:
        try:
            is_stream = bool(json.loads(body).get("stream"))
        except (json.JSONDecodeError, AttributeError):
            pass

    log.info("%s %s → %s (stream=%s)", request.method, request.url.path, target_url, is_stream)

    if is_stream:
        async def generate() -> AsyncIterator[bytes]:
            async with _client.stream(
                request.method,
                target_url,
                content=body,
                headers=headers,
                params=dict(request.query_params),
            ) as upstream:
                log.debug("Streaming status=%s from %s", upstream.status_code, target_url)
                async for chunk in upstream.aiter_raw():
                    yield chunk

        return StreamingResponse(
            generate(),
            media_type="text/event-stream",
            headers={"X-Accel-Buffering": "no", "Cache-Control": "no-cache"},
        )

    r = await _client.request(
        request.method,
        target_url,
        content=body,
        headers=headers,
        params=dict(request.query_params),
    )
    resp_headers = {k: v for k, v in r.headers.items() if k.lower() not in _STRIP_RESPONSE}
    log.debug("Proxied status=%s from %s", r.status_code, target_url)
    return Response(r.content, r.status_code, resp_headers)


@app.api_route("/v1/responses", methods=["GET", "POST", "DELETE"])
@app.api_route("/v1/responses/{path:path}", methods=["GET", "POST", "DELETE"])
async def responses_api(request: Request, path: str = "") -> Response:
    """Responses API — always routes to server1 (stateful via previous_response_id)."""
    suffix = f"/{path}" if path else ""
    return await _forward(f"{SERVER1}/v1/responses{suffix}", request)


@app.api_route("/v1/chat/completions", methods=["POST"])
async def chat_completions(request: Request) -> Response:
    """Chat completions — round-robin load balanced across both servers."""
    target = next(_chat_servers)
    return await _forward(f"{target}/v1/chat/completions", request)


@app.get("/health")
async def health() -> dict:
    return {"status": "ok", "server1": SERVER1, "server2": SERVER2}


@app.api_route("/{path:path}", methods=["GET", "POST", "PUT", "DELETE", "PATCH"])
async def catch_all(request: Request, path: str = "") -> Response:
    """All other endpoints — pass through to server1."""
    return await _forward(f"{SERVER1}/{path}", request)
