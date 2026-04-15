#!/usr/bin/env python3
"""
Patch vLLM chat_utils.py to handle malformed JSON in tool call arguments.

Root cause: In multi-turn tool-call conversations, _postprocess_messages() calls
json.loads() on tool call arguments. The qwen3_coder streaming parser can produce
argument strings with trailing data that causes json.loads() to raise "Extra data".

Fix: wrap json.loads() in try/except and fall back to JSONDecoder.raw_decode()
which ignores trailing data after a valid JSON value.

This script is idempotent - safe to run multiple times.
"""
import pathlib
import re
import sys

CHAT_UTILS = pathlib.Path(
    "/usr/local/lib/python3.12/dist-packages/vllm/entrypoints/chat_utils.py"
)

if not CHAT_UTILS.exists():
    print(f"patch-vllm: {CHAT_UTILS} not found, skipping", flush=True)
    sys.exit(0)

content = CHAT_UTILS.read_text()

if "ARGS_PARSE_ERR" in content:
    print("patch-vllm: already applied, skipping", flush=True)
    sys.exit(0)

# Match the json.loads line regardless of indentation level
pattern = r'( +)(item\["function"\]\["arguments"\] = json\.loads\(content\))'
m = re.search(pattern, content)
if not m:
    print("patch-vllm: target line not found, may be a different vLLM version", flush=True)
    sys.exit(0)

indent = m.group(1)
old_line = m.group(0)
new_block = (
    indent + 'try:\n' +
    indent + '    item["function"]["arguments"] = json.loads(content)\n' +
    indent + 'except Exception as _e:\n' +
    indent + '    import logging as _log\n' +
    indent + '    _log.getLogger("vllm").warning(\n' +
    indent + '        "ARGS_PARSE_ERR len=%d repr=%r err=%s",\n' +
    indent + '        len(content), content[:300], _e\n' +
    indent + '    )\n' +
    indent + '    _dec = __import__("json").JSONDecoder()\n' +
    indent + '    item["function"]["arguments"], _ = _dec.raw_decode(content)'
)

new_content = content.replace(old_line, new_block)
if new_content == content:
    print("patch-vllm: replace had no effect!", flush=True)
    sys.exit(1)

CHAT_UTILS.write_text(new_content)
print(f"patch-vllm: applied at indent={len(indent)} to {CHAT_UTILS}", flush=True)
