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

import re

# Strip fenced code blocks and inline code first: a model explaining this
# hook often quotes a tool-call tag as an EXAMPLE inside ``` or `...`, and
# that quote must not count as a real malformed call.
def strip_code(text):
    text = re.sub(r"(?ms)^[ \t]*```.*?^[ \t]*```", "", text)
    text = re.sub(r"`[^`\n]*`", "", text)
    return text

# Real malformed tool calls carry an OPENING signature tag with a name=
# attribute, serialized as markup at the start of a line (after optional
# indentation). Prose that merely mentions the tags — e.g. while editing
# this very hook — embeds them mid-sentence or inside backticks, so we
# anchor to line-start and ignore code-quoted examples to avoid false
# positives.
invoke = "in" + "voke"
parameter = "para" + "meter"
signature = re.compile(r"(?m)^[ \t]*<(?:" + invoke + "|" + parameter + r")\s+name=")
sys.exit(0 if signature.search(strip_code(last_text)) else 1)
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
        echo "Malformed tool call persisted after $MAX_BLOCKS retries — not blocking again to avoid a loop. The same call keeps failing to serialize; the cause is usually a multi-line bash command with a heredoc or nested quotes inside \$(...). STOP retrying the same shape: split the command into separate single-purpose tool calls, drop the heredoc, or write the script to a file first. Then tell the user what failed." >&2
        exit 2
    fi

    emit_block "$BLOCK_REASON (retry $attempts/$MAX_BLOCKS)"
    exit 0
}

main
