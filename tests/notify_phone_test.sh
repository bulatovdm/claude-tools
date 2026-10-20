#!/bin/bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
HOOK="$SCRIPT_DIR/scripts/hooks/notify-phone.sh"

# Set inside Claude Code; the tests pass their own per case.
unset CLAUDE_PROJECT_DIR

PASS=0
FAIL=0

WORK_DIR=$(mktemp -d)
CURL_LOG="$WORK_DIR/curl.log"
CONFIG="$WORK_DIR/notify.env"
STATE_DIR="$WORK_DIR/state"

cleanup() {
    rm -rf "$WORK_DIR"
}
trap cleanup EXIT

mkdir -p "$WORK_DIR/bin"
cat > "$WORK_DIR/bin/curl" << EOF
#!/bin/bash
printf '%s\n' "\$@" >> "$CURL_LOG"
EOF
chmod +x "$WORK_DIR/bin/curl"

# The hook looks up its claude ancestor by process name; a symlink gives a
# shell that name, so the real Claude Code session running the tests is never seen.
FAKE_CLAUDE="$WORK_DIR/claude"
ln -s /bin/bash "$FAKE_CLAUDE"

assert_equals() {
    local test_name=$1
    local actual=$2
    local expected=$3

    if [[ "$actual" == "$expected" ]]; then
        PASS=$((PASS + 1))
        echo "  PASS: $test_name"
    else
        FAIL=$((FAIL + 1))
        echo "  FAIL: $test_name"
        echo "    Expected: $expected"
        echo "    Actual: $actual"
    fi
}

assert_contains() {
    local test_name=$1
    local actual=$2
    local expected=$3

    if grep -qF -- "$expected" <<< "$actual"; then
        PASS=$((PASS + 1))
        echo "  PASS: $test_name"
    else
        FAIL=$((FAIL + 1))
        echo "  FAIL: $test_name"
        echo "    Expected to contain: $expected"
        echo "    Actual: $actual"
    fi
}

assert_not_contains() {
    local test_name=$1
    local actual=$2
    local unexpected=$3

    if grep -qF -- "$unexpected" <<< "$actual"; then
        FAIL=$((FAIL + 1))
        echo "  FAIL: $test_name"
        echo "    Expected NOT to contain: $unexpected"
        echo "    Actual: $actual"
    else
        PASS=$((PASS + 1))
        echo "  PASS: $test_name"
    fi
}

hook_payload() {
    local event=$1 notification_type=$2 transcript=$3
    jq -n --arg event "$event" --arg type "$notification_type" --arg transcript "$transcript" \
        --arg cwd "${PAYLOAD_CWD:-/Users/me/Projects/mediteka}" \
        --arg prompt "${PAYLOAD_PROMPT:-Продолжаем}" '{
        session_id: "abc",
        cwd: $cwd,
        transcript_path: $transcript,
        hook_event_name: $event,
        notification_type: $type,
        prompt: $prompt,
        message: "Claude needs your permission to use Bash: cat secret-report.pdf"
    }'
}

# Runs the hook as a child of a fake claude process that, when given a
# background command, also runs it the way Claude Code runs Monitor/Bash tasks:
# a Monitor's stdout is a pipe, a background Bash command's is a file
# (set TASK_STDOUT). Extra arguments land in the fake claude's command line (e.g. -p).
run_hook_in_session() {
    local event=$1 notification_type=$2 transcript=${3:-} background_command=${4:-}
    shift $(($# < 4 ? $# : 4))
    hook_payload "$event" "$notification_type" "$transcript" \
        | PATH="$WORK_DIR/bin:$PATH" CLAUDE_NOTIFY_CONFIG="$CONFIG" CLAUDE_NOTIFY_STATE_DIR="$STATE_DIR" TASK_STDOUT="${TASK_STDOUT:-}" \
            CLAUDE_PROJECT_DIR="${CLAUDE_PROJECT_DIR:-}" \
            "$FAKE_CLAUDE" -c '
            hook=$1 background_command=$2
            if [[ -n "$background_command" ]]; then
                if [[ -n "$TASK_STDOUT" ]]; then
                    /bin/bash -c "$background_command; : shell-snapshots/snapshot-test" < /dev/null > "$TASK_STDOUT" 2> /dev/null &
                else
                    /bin/bash -c "$background_command; : shell-snapshots/snapshot-test" < /dev/null > >(cat > /dev/null) 2> /dev/null &
                fi
                task_pid=$!
                sleep 1
            fi
            /bin/bash "$hook"
            if [[ -n "${task_pid:-}" ]]; then
                pkill -P "$task_pid"
                kill "$task_pid" 2> /dev/null
            fi
            true
        ' fake-claude "$HOOK" "$background_command" "$@"
}

notify_on() {
    rm -f "$CURL_LOG"
    run_hook_in_session Notification "$1" "${2:-}"
}

stop_turn() {
    local transcript=${1:-} background_command=${2:-}
    shift $(($# < 2 ? $# : 2))
    run_hook_in_session Stop "" "$transcript" "$background_command" "$@"
}

submit_prompt() {
    run_hook_in_session UserPromptSubmit ""
}

# What Claude Code passes to UserPromptSubmit when a Monitor event wakes the session.
deliver_monitor_event() {
    PAYLOAD_PROMPT='<task-notification>
<task-id>btbnw4d6i</task-id>
<summary>Monitor event: "шина empirika"</summary>
</task-notification>' run_hook_in_session UserPromptSubmit ""
}

sent_requests() {
    cat "$CURL_LOG" 2>/dev/null || true
}

# A fresh session: no requests sent, no prompt or earlier report on record.
reset_requests() {
    rm -f "$CURL_LOG"
    rm -rf "$STATE_DIR"
}

count_sent() {
    grep -c "$1" "$CURL_LOG" 2>/dev/null || true
}

echo "ntfy:"
echo 'NTFY_TOPIC=claude-test-topic' > "$CONFIG"
notify_on permission_prompt
assert_contains "posts to ntfy.sh" "$(sent_requests)" "https://ntfy.sh"
assert_contains "uses the configured topic" "$(sent_requests)" '"topic":"claude-test-topic"'
assert_contains "titles with the project name" "$(sent_requests)" '"title":"Claude · mediteka"'
assert_contains "describes a permission prompt" "$(sent_requests)" "Needs permission"
assert_not_contains "never sends Claude's message text" "$(sent_requests)" "secret-report"

echo 'NTFY_TOPIC=t
NTFY_SERVER=https://ntfy.example.com' > "$CONFIG"
notify_on permission_prompt
assert_contains "honours a self-hosted server" "$(sent_requests)" "https://ntfy.example.com"

echo "filtering:"
echo 'NTFY_TOPIC=t' > "$CONFIG"
notify_on idle_prompt
assert_equals "ignores the built-in 60 s idle_prompt" "$(sent_requests)" ""
notify_on auth_success
assert_equals "ignores auth_success" "$(sent_requests)" ""
notify_on elicitation_complete
assert_equals "ignores elicitation_complete" "$(sent_requests)" ""

rm -f "$CONFIG"
notify_on permission_prompt
assert_equals "does nothing without a config" "$(sent_requests)" ""

echo "waiting for a reply after a turn:"
echo 'NTFY_TOPIC=t
IDLE_NOTIFY_SECONDS=1
BACKGROUND_WAIT_LIMIT_SECONDS=2' > "$CONFIG"
reset_requests
stop_turn
assert_contains "reports a finished turn after the delay" "$(sent_requests)" "Waiting for your reply"

reset_requests
stop_turn &
sleep 0.3
submit_prompt
wait
assert_equals "a prompt sent during the delay cancels it" "$(sent_requests)" ""

reset_requests
stop_turn &
sleep 0.3
stop_turn
wait
assert_equals "a newer turn replaces the pending report" "$(count_sent "Waiting for your reply")" "1"

reset_requests
stop_turn
stop_turn
assert_equals "reports once until you reply" "$(count_sent "Waiting for your reply")" "1"
submit_prompt
stop_turn
assert_equals "reports again after your next prompt" "$(count_sent "Waiting for your reply")" "2"

reset_requests
stop_turn
deliver_monitor_event
PAYLOAD_PROMPT='Another Claude session sent a message: <cross-session-message from="uds:/tmp/cc-socks/1.sock">hi</cross-session-message>' \
    run_hook_in_session UserPromptSubmit ""
stop_turn
assert_equals "events and other sessions' messages are not your reply" "$(count_sent "Waiting for your reply")" "1"

reset_requests
stop_turn "" "" -p
assert_equals "stays quiet for claude -p runs" "$(sent_requests)" ""

jq -nc --arg ts "$(date -u -v+5S +%Y-%m-%dT%H:%M:%S.000Z)" \
    '{type: "user", timestamp: $ts, message: {content: "<task-notification>done</task-notification>"}}' \
    > "$WORK_DIR/resumed.jsonl"
reset_requests
stop_turn "$WORK_DIR/resumed.jsonl"
assert_equals "stays quiet when Claude resumes on its own" "$(sent_requests)" ""

echo "sessions waiting for their own events:"
reset_requests
submit_prompt
stop_turn "" "sleep 30"
assert_contains "a monitor (a listener, re-armed for good) does not hold the report" "$(sent_requests)" "Waiting for your reply"
assert_not_contains "and is not mentioned in it" "$(sent_requests)" "background task"

readonly BACKGROUND_BASH_OUTPUT="$WORK_DIR/task.output"
reset_requests
submit_prompt
TASK_STDOUT="$BACKGROUND_BASH_OUTPUT" stop_turn "" "sleep 30"
assert_contains "holds the report for a background command started after your prompt, up to the limit" \
    "$(sent_requests)" "a background task is still running"

reset_requests
submit_prompt
TASK_STDOUT="$BACKGROUND_BASH_OUTPUT" stop_turn "" "sleep 30" &
sleep 1.5
submit_prompt
wait
assert_equals "a prompt while the report is held cancels it" "$(sent_requests)" ""

reset_requests
submit_prompt
TASK_STDOUT="$BACKGROUND_BASH_OUTPUT" stop_turn "" "sleep 30" &
sleep 1.5
deliver_monitor_event
wait
assert_contains "a monitor event does not release a held report early" \
    "$(sent_requests)" "a background task is still running"

reset_requests
mkdir -p "$STATE_DIR"
echo $(($(date +%s) + 100)) > "$STATE_DIR/abc.prompted"
TASK_STDOUT="$BACKGROUND_BASH_OUTPUT" stop_turn "" "sleep 30"
assert_contains "ignores a leftover background command older than your prompt" "$(sent_requests)" "Waiting for your reply"
assert_not_contains "and reports without holding for it" "$(sent_requests)" "background task"

reset_requests
TASK_STDOUT="$BACKGROUND_BASH_OUTPUT" stop_turn "" "sleep 30"
assert_not_contains "ignores background commands until a prompt is on record" "$(sent_requests)" "background task"

reset_requests
run_hook_in_session Notification permission_prompt "" "sleep 30"
assert_contains "still reports permission prompts during a monitor" "$(sent_requests)" "Needs permission"

reset_requests
submit_prompt
TASK_STDOUT="$BACKGROUND_BASH_OUTPUT" stop_turn "" "python3 -m http.server 0 --bind 127.0.0.1 > /dev/null 2>&1"
assert_not_contains "ignores a background server: Claude does not wait on it" "$(sent_requests)" "background task"

transcript_ending_with_tool() {
    local tool_input=$1
    jq -nc --argjson input "$tool_input" '{type: "assistant", message: {content: [
        {type: "text", text: "Next check later"},
        {type: "tool_use", name: "ScheduleWakeup", input: $input}
    ]}}' > "$WORK_DIR/transcript.jsonl"
    echo "$WORK_DIR/transcript.jsonl"
}

reset_requests
stop_turn "$(transcript_ending_with_tool '{"delaySeconds": 1200}')"
assert_equals "stays quiet while a /loop waits for its wakeup" "$(sent_requests)" ""

reset_requests
stop_turn "$(transcript_ending_with_tool '{"stop": true}')"
assert_contains "reports once the /loop has stopped" "$(sent_requests)" "Waiting for your reply"

echo "what the permission prompt is for:"
echo 'NTFY_TOPIC=t' > "$CONFIG"
transcript_with_pending_tool() {
    local tool_name=$1 answered=${2:-}
    jq -nc --arg name "$tool_name" '{type: "assistant", message: {content: [
        {type: "text", text: "Before I go on"},
        {type: "tool_use", id: "toolu_1", name: $name, input: {}}
    ]}}' > "$WORK_DIR/pending-tool.jsonl"
    if [[ -n "$answered" ]]; then
        jq -nc '{type: "user", message: {content: [{type: "tool_result", tool_use_id: "toolu_1", content: "ok"}]}}' \
            >> "$WORK_DIR/pending-tool.jsonl"
    fi
    echo "$WORK_DIR/pending-tool.jsonl"
}

notify_on permission_prompt "$(transcript_with_pending_tool AskUserQuestion)"
assert_contains "names a question with options" "$(sent_requests)" "Claude asks you a question"

notify_on permission_prompt "$(transcript_with_pending_tool ExitPlanMode)"
assert_contains "names a plan to approve" "$(sent_requests)" "Plan awaits your approval"

notify_on permission_prompt "$(transcript_with_pending_tool Bash)"
assert_contains "keeps a tool permission as such" "$(sent_requests)" "Needs permission"

notify_on permission_prompt "$(transcript_with_pending_tool AskUserQuestion answered)"
assert_contains "ignores a question already answered" "$(sent_requests)" "Needs permission"

echo "session title:"
echo 'NTFY_TOPIC=t' > "$CONFIG"
printf '%s\n' \
    '{"type":"ai-title","aiTitle":"Old auto title","sessionId":"abc"}' \
    '{"type":"ai-title","aiTitle":"Синхронизация с Mac","sessionId":"abc"}' \
    > "$WORK_DIR/auto-titled.jsonl"
notify_on permission_prompt "$WORK_DIR/auto-titled.jsonl"
assert_contains "appends the latest auto title" "$(sent_requests)" '"title":"Claude · mediteka · Синхронизация с Mac"'

cp "$WORK_DIR/auto-titled.jsonl" "$WORK_DIR/renamed.jsonl"
echo '{"type":"custom-title","customTitle":"sync","sessionId":"abc"}' >> "$WORK_DIR/renamed.jsonl"
echo '{"type":"ai-title","aiTitle":"Newer auto title","sessionId":"abc"}' >> "$WORK_DIR/renamed.jsonl"
notify_on permission_prompt "$WORK_DIR/renamed.jsonl"
assert_contains "prefers the /rename title" "$(sent_requests)" '"title":"Claude · mediteka · sync"'

echo '{"type":"user","message":{"content":"hi"}}' > "$WORK_DIR/untitled.jsonl"
notify_on permission_prompt "$WORK_DIR/untitled.jsonl"
assert_contains "keeps the bare project when untitled" "$(sent_requests)" '"title":"Claude · mediteka"'

echo "project name:"
echo 'NTFY_TOPIC=t' > "$CONFIG"
readonly REPO="$WORK_DIR/empirika"
mkdir -p "$REPO/packages/server/src"
git -C "$REPO" init -q
git -C "$REPO" -c user.name=t -c user.email=t@t commit -q --allow-empty -m init
git -C "$REPO" worktree add -q "$REPO/.claude/worktrees/client-place-pair" 2> /dev/null
mkdir -p "$REPO/.claude/worktrees/client-place-pair/packages/web/src"

PAYLOAD_CWD="$REPO/packages/server/src" CLAUDE_PROJECT_DIR="$REPO" notify_on permission_prompt
assert_contains "names the project the session started in, not the cd target" "$(sent_requests)" '"title":"Claude · empirika"'

PAYLOAD_CWD="$REPO/packages/server/src" notify_on permission_prompt
assert_contains "resolves a subfolder cwd to the repository root" "$(sent_requests)" '"title":"Claude · empirika"'

PAYLOAD_CWD="$REPO/.claude/worktrees/client-place-pair/packages/web/src" \
    CLAUDE_PROJECT_DIR="$REPO/.claude/worktrees/client-place-pair" notify_on permission_prompt
assert_contains "names a worktree after its repository" "$(sent_requests)" '"title":"Claude · empirika (client-place-pair)"'

PAYLOAD_CWD="$WORK_DIR/plain/project" notify_on permission_prompt
assert_contains "falls back to the folder name outside git" "$(sent_requests)" '"title":"Claude · project"'

echo "telegram:"
echo 'TELEGRAM_BOT_TOKEN=123:abc
TELEGRAM_CHAT_ID=42' > "$CONFIG"
notify_on permission_prompt
assert_contains "posts to the bot API" "$(sent_requests)" "https://api.telegram.org/bot123:abc/sendMessage"
assert_contains "sends to the configured chat" "$(sent_requests)" "chat_id=42"
assert_not_contains "skips ntfy without a topic" "$(sent_requests)" "ntfy.sh"

echo
echo "Passed: $PASS, Failed: $FAIL"
[[ $FAIL -eq 0 ]]
