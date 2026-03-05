#!/bin/bash

set -euo pipefail

input=$(cat)
session_id=$(echo "$input" | jq -r '.session_id // empty')
model=$(echo "$input" | jq -r '.model.display_name // empty')

[[ -z "$session_id" ]] && exit 0
[[ -z "$model" ]] && exit 0

echo "$model" > "/tmp/claude-model-${session_id}"
