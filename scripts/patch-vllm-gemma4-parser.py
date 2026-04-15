#!/usr/bin/env python3
"""
Patch vLLM gemma4_tool_parser.py to fix skip_special_tokens for ResponsesRequest.

Root cause: The adjust_request() method only sets skip_special_tokens=False for
ChatCompletionRequest, not ResponsesRequest. When Gemma4 tool calls go through
vLLM's /v1/responses endpoint, the <|tool_call> and <tool_call|> special tokens
get filtered out (skip_special_tokens=True by default in ResponsesRequest), so the
parser never sees the delimiters and tool calls appear as raw text in output_text.

Fix: Remove the isinstance(request, ChatCompletionRequest) guard so that
skip_special_tokens=False applies to both ChatCompletionRequest and ResponsesRequest
whenever tools are provided and tool_choice != "none".

This script is idempotent — safe to run multiple times.
"""
import pathlib
import sys

PARSER_FILE = pathlib.Path(
    "/usr/local/lib/python3.12/dist-packages/vllm/tool_parsers/gemma4_tool_parser.py"
)

if not PARSER_FILE.exists():
    print(f"patch-vllm-gemma4: {PARSER_FILE} not found, skipping", flush=True)
    sys.exit(0)

content = PARSER_FILE.read_text()

if "GEMMA4_RESPONSES_PATCH" in content:
    print("patch-vllm-gemma4: already applied, skipping", flush=True)
    sys.exit(0)

OLD_CODE = '''        if (
            isinstance(request, ChatCompletionRequest)
            and request.tools
            and request.tool_choice != "none"
        ):
            # Don't skip special tokens — <|tool_call> etc. are needed
            request.skip_special_tokens = False'''

NEW_CODE = '''        # GEMMA4_RESPONSES_PATCH: apply to both ChatCompletionRequest and ResponsesRequest
        if (
            request.tools
            and request.tool_choice != "none"
        ):
            # Don't skip special tokens — <|tool_call> etc. are needed
            request.skip_special_tokens = False'''

if OLD_CODE not in content:
    print(
        "patch-vllm-gemma4: target code not found — skipping (different vLLM version?)",
        flush=True,
    )
    sys.exit(0)

new_content = content.replace(OLD_CODE, NEW_CODE, 1)
PARSER_FILE.write_text(new_content)

# Invalidate compiled bytecode so Python uses the patched source
pyc = PARSER_FILE.with_suffix(".pyc")
if pyc.exists():
    pyc.unlink()

import importlib
cache_dir = PARSER_FILE.parent / "__pycache__"
if cache_dir.exists():
    for pyc_file in cache_dir.glob("gemma4_tool_parser*.pyc"):
        pyc_file.unlink()

print("patch-vllm-gemma4: successfully patched gemma4_tool_parser.py", flush=True)
