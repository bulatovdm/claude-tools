#!/bin/bash

set -euo pipefail

readonly DISABLE_FLAG="$HOME/.claude/.disable-malformed-toolcall-hook"
readonly ATTEMPT_DIR="$HOME/.claude/.malformed-toolcall-attempts"
readonly MAX_BLOCKS=3

readonly BLOCK_REASON="Your previous message contains a MALFORMED tool call left as raw text: an unparsed tool-invocation block that did not become a real tool_use (often a stray closing tag after a heredoc, or a missing opening tag). Re-issue that exact tool call NOW with correct invocation syntax. Do not stop and do not wait for the user — just repeat the call correctly."

is_disabled() {
    [[ -f "$DISABLE_FLAG" ]]
}

session_id_of() {
    echo "$1" | jq -r '.session_id // "default"'
}

transcript_path_of() {
    echo "$1" | jq -r '.transcript_path // empty'
}

attempt_file_for() {
    echo "$ATTEMPT_DIR/$1"
}

read_attempts() {
    local file="$1"
    [[ -f "$file" ]] && cat "$file" 2>/dev/null || echo 0
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
    jq -n --arg reason "$1" '{decision: "block", reason: $reason}'
}

main() {
    is_disabled && exit 0

    local payload
    payload=$(cat)

    local transcript
    transcript=$(transcript_path_of "$payload")
    [[ -z "$transcript" || ! -f "$transcript" ]] && exit 0

    local session attempt_file attempts
    session=$(session_id_of "$payload")
    attempt_file=$(attempt_file_for "$session")

    if ! last_assistant_message_has_raw_toolcall "$transcript"; then
        rm -f "$attempt_file"
        exit 0
    fi

    mkdir -p "$ATTEMPT_DIR"
    attempts=$(read_attempts "$attempt_file")
    attempts=$((attempts + 1))
    echo "$attempts" > "$attempt_file"

    if (( attempts > MAX_BLOCKS )); then
        rm -f "$attempt_file"
        echo "Malformed tool call persisted after $MAX_BLOCKS retries; stopping to avoid a loop. Please fix the tool-call syntax manually." >&2
        exit 0
    fi

    emit_block "$BLOCK_REASON (retry $attempts/$MAX_BLOCKS)"
    exit 0
}

main
