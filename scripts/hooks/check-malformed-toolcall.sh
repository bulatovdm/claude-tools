#!/bin/bash

set -euo pipefail

readonly DISABLE_FLAG="$HOME/.claude/.disable-malformed-toolcall-hook"

readonly BLOCK_REASON="Your previous message contains a MALFORMED tool call left as raw text: an unparsed tool-invocation block that did not become a real tool_use (often after a stray \"count\" opening tag). Re-issue that exact tool call NOW with correct invocation syntax. Do not stop and do not wait for the user — just repeat the call correctly."

is_disabled() {
    [[ -f "$DISABLE_FLAG" ]]
}

is_reentrant_stop() {
    local payload="$1"
    [[ "$(echo "$payload" | jq -r '.stop_hook_active // false')" == "true" ]]
}

transcript_path_of() {
    echo "$1" | jq -r '.transcript_path // empty'
}

last_assistant_message_has_raw_toolcall() {
    local transcript="$1"

    python3 - "$transcript" <<'PY'
import json, sys

path = sys.argv[1]
last_text = None

with open(path) as f:
    for line in f:
        line = line.strip()
        if not line:
            continue
        try:
            entry = json.loads(line)
        except Exception:
            continue
        if entry.get("type") != "assistant":
            continue
        texts = [
            block.get("text", "")
            for block in entry.get("message", {}).get("content", [])
            if isinstance(block, dict) and block.get("type") == "text"
        ]
        if texts:
            last_text = "\n".join(texts)

if last_text is None:
    sys.exit(1)

invoke = "in" + "voke name="
parameter = "para" + "meter name="
markers = ["<" + invoke, "<" + parameter, "</" + "in" + "voke>", "</" + "para" + "meter>"]
sys.exit(0 if any(marker in last_text for marker in markers) else 1)
PY
}

emit_block() {
    jq -n --arg reason "$BLOCK_REASON" '{decision: "block", reason: $reason}'
}

main() {
    is_disabled && exit 0

    local payload
    payload=$(cat)

    is_reentrant_stop "$payload" && exit 0

    local transcript
    transcript=$(transcript_path_of "$payload")
    [[ -z "$transcript" || ! -f "$transcript" ]] && exit 0

    if last_assistant_message_has_raw_toolcall "$transcript"; then
        emit_block
    fi

    exit 0
}

main
