#!/bin/bash

set -euo pipefail

readonly NOTIFY_CONFIG="${CLAUDE_NOTIFY_CONFIG:-$HOME/.claude/notify.env}"
readonly PENDING_REPLY_DIR="${CLAUDE_NOTIFY_PENDING_DIR:-/tmp/claude-notify-pending}"
readonly DEFAULT_IDLE_NOTIFY_SECONDS=30
readonly WAITING_FOR_REPLY="💬 Waiting for your reply"
readonly DEFAULT_NTFY_SERVER="https://ntfy.sh"
readonly REQUEST_TIMEOUT_SECONDS=10
readonly BACKGROUND_TASK_MARKER="shell-snapshots/snapshot-"
readonly MAX_PROCESS_DEPTH=10
readonly TRANSCRIPT_TAIL_LINES=200
# Claude Code re-appends title entries throughout the transcript, so the tail
# holds the current ones; grepping a multi-hundred-MB file takes seconds.
readonly TITLE_SEARCH_TAIL_BYTES=5000000
readonly ACTIVITY_SEARCH_TAIL_BYTES=2000000

# Only the notification type and project name leave the machine: Claude's
# message can contain commands and file paths, which may be private.
# idle_prompt is left out: Claude Code sends it after a fixed 60 s, so the
# Stop handler below reports a waiting reply on its own, shorter timer.
describe_notification() {
    case "$1" in
        permission_prompt)      echo "🔐 Needs permission" ;;
        elicitation_dialog)     echo "📝 MCP server asks for input" ;;
        elicitation_url_dialog) echo "🌐 MCP server asks to open a URL" ;;
        agent_needs_input)      echo "🙋 Background session needs input" ;;
        *)                      return 1 ;;
    esac
}

find_claude_pid() {
    local pid=$PPID depth
    for ((depth = 0; depth < MAX_PROCESS_DEPTH; depth++)); do
        [[ "$pid" -gt 1 ]] || return 1
        if [[ "$(basename "$(ps -o comm= -p "$pid")")" == "claude" ]]; then
            echo "$pid"
            return 0
        fi
        pid=$(ps -o ppid= -p "$pid" | tr -d ' ')
    done
    return 1
}

list_process_tree() {
    local pid=$1 child
    echo "$pid"
    for child in $(pgrep -P "$pid"); do
        list_process_tree "$child"
    done
}

# A background server (dev server, etc.) is not something Claude waits on.
listens_on_tcp() {
    local pids
    pids=$(list_process_tree "$1" | paste -sd, -)
    lsof -a -nP -iTCP -sTCP:LISTEN -p "$pids" > /dev/null 2>&1
}

# Monitors and background Bash commands run as children of the claude
# process; while one is alive, the session waits for its event, not for you.
has_running_background_task() {
    local claude_pid task_pid
    claude_pid=$(find_claude_pid) || return 1
    for task_pid in $(pgrep -P "$claude_pid" -f "$BACKGROUND_TASK_MARKER"); do
        listens_on_tcp "$task_pid" || return 0
    done
    return 1
}

waits_for_loop_wakeup() {
    local transcript=$1
    [[ -f "$transcript" ]] || return 1
    tail -n "$TRANSCRIPT_TAIL_LINES" "$transcript" | jq -rs '
        [.[] | select(.type == "assistant") | .message.content[]?
             | select(.type == "tool_use")] | last
        | select(.name == "ScheduleWakeup" and .input.stop != true) | .name
    ' 2>/dev/null | grep -q .
}

# A /rename title wins over the auto-generated one; the latest entry of each counts.
find_session_title() {
    local transcript=$1 title_entries title
    [[ -f "$transcript" ]] || return 0
    title_entries=$(tail -c "$TITLE_SEARCH_TAIL_BYTES" "$transcript" \
        | LC_ALL=C grep -F -e '"type":"custom-title"' -e '"type":"ai-title"' || true)
    title=$(grep -F '"type":"custom-title"' <<< "$title_entries" | tail -n 1 | jq -r '.customTitle // empty' 2>/dev/null || true)
    if [[ -z "$title" ]]; then
        title=$(grep -F '"type":"ai-title"' <<< "$title_entries" | tail -n 1 | jq -r '.aiTitle // empty' 2>/dev/null || true)
    fi
    echo "$title"
}

session_waits_for_own_event() {
    has_running_background_task || waits_for_loop_wakeup "$1"
}

# claude -p runs (scripts, automations) end with Stop too, but nobody waits on them.
is_print_mode() {
    local claude_pid
    claude_pid=$(find_claude_pid) || return 1
    ps -o args= -p "$claude_pid" | grep -qE '(^| )(-p|--print)( |$)'
}

# Monitor events and finished background tasks start a new turn without a
# prompt from you; such a turn writes user/assistant entries to the transcript.
session_resumed_since() {
    local transcript=$1 since=$2
    [[ -f "$transcript" ]] || return 1
    tail -c "$ACTIVITY_SEARCH_TAIL_BYTES" "$transcript" | jq -Rr --argjson since "$since" '
        fromjson? | select(.type == "user" or .type == "assistant") | .timestamp // empty
        | sub("\\.[0-9]+Z$"; "Z") | fromdateiso8601 | select(. > $since)
    ' 2>/dev/null | grep -q .
}

send_ntfy() {
    local title=$1 body=$2
    local payload
    payload=$(jq -nc --arg topic "$NTFY_TOPIC" --arg title "$title" --arg message "$body" \
        '{topic: $topic, title: $title, message: $message, priority: 4}')
    curl -fsS --max-time "$REQUEST_TIMEOUT_SECONDS" \
        -H "Content-Type: application/json" \
        -d "$payload" "${NTFY_SERVER:-$DEFAULT_NTFY_SERVER}" > /dev/null
}

send_telegram() {
    local title=$1 body=$2
    curl -fsS --max-time "$REQUEST_TIMEOUT_SECONDS" \
        --data-urlencode "chat_id=$TELEGRAM_CHAT_ID" \
        --data-urlencode "text=$title — $body" \
        "https://api.telegram.org/bot$TELEGRAM_BOT_TOKEN/sendMessage" > /dev/null
}

notify() {
    local cwd=$1 transcript=$2 body=$3
    local title session_title
    title="Claude · $(basename "${cwd:-$PWD}")"
    session_title=$(find_session_title "$transcript")
    if [[ -n "$session_title" ]]; then
        title="$title · $session_title"
    fi

    if [[ -n "${NTFY_TOPIC:-}" ]]; then
        send_ntfy "$title" "$body"
    fi
    if [[ -n "${TELEGRAM_BOT_TOKEN:-}" && -n "${TELEGRAM_CHAT_ID:-}" ]]; then
        send_telegram "$title" "$body"
    fi
}

handle_notification() {
    local cwd=$1 transcript=$2 notification_type=$3 body
    body=$(describe_notification "$notification_type") || return 0
    notify "$cwd" "$transcript" "$body"
}

# The pending file holds a token of the latest Stop; a newer Stop or your
# prompt replaces or removes it, which cancels the earlier wait.
handle_stop() {
    local cwd=$1 transcript=$2 session_id=$3
    is_print_mode && return 0

    local pending_file="$PENDING_REPLY_DIR/$session_id" stopped_at token
    stopped_at=$(date +%s)
    token="$stopped_at-$$"
    mkdir -p "$PENDING_REPLY_DIR"
    echo "$token" > "$pending_file"

    sleep "${IDLE_NOTIFY_SECONDS:-$DEFAULT_IDLE_NOTIFY_SECONDS}"

    [[ "$(cat "$pending_file" 2>/dev/null)" == "$token" ]] || return 0
    rm -f "$pending_file"
    session_resumed_since "$transcript" "$stopped_at" && return 0
    session_waits_for_own_event "$transcript" && return 0
    notify "$cwd" "$transcript" "$WAITING_FOR_REPLY"
}

cancel_pending_reply() {
    rm -f "$PENDING_REPLY_DIR/$1"
}

main() {
    local input
    input=$(cat)

    [[ -f "$NOTIFY_CONFIG" ]] || exit 0
    # shellcheck source=/dev/null
    source "$NOTIFY_CONFIG"

    local event cwd transcript session_id
    event=$(jq -r '.hook_event_name // empty' <<< "$input")
    cwd=$(jq -r '.cwd // empty' <<< "$input")
    transcript=$(jq -r '.transcript_path // empty' <<< "$input")
    session_id=$(jq -r '.session_id // empty' <<< "$input")
    [[ -n "$session_id" ]] || exit 0

    case "$event" in
        Notification)
            handle_notification "$cwd" "$transcript" "$(jq -r '.notification_type // empty' <<< "$input")" ;;
        Stop)
            handle_stop "$cwd" "$transcript" "$session_id" ;;
        UserPromptSubmit)
            cancel_pending_reply "$session_id" ;;
    esac
}

main
