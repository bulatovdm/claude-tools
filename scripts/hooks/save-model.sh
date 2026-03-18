#!/bin/bash

set -euo pipefail

input=$(cat)
session_id=$(echo "$input" | jq -r '.session_id // empty')
model_display=$(echo "$input" | jq -r '.model.display_name // empty')
model_id=$(echo "$input" | jq -r '.model.id // empty')

[[ -z "$session_id" ]] && exit 0
[[ -z "$model_display" ]] && exit 0

echo "$model_display" > "/tmp/claude-model-${session_id}"
[[ -n "$model_id" ]] && echo "$model_id" > "/tmp/claude-model-id-${session_id}"
[[ -f "/tmp/claude-ctx-${session_id}" ]] && rm -f "/tmp/claude-ctx-${session_id}"
