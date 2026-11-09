#!/bin/bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SESSION_SCRIPT="$SCRIPT_DIR/scripts/session.sh"

PASS=0
FAIL=0

WORK_DIR=$(mktemp -d)
trap 'rm -rf "$WORK_DIR"' EXIT

TEST_SCRIPT="$WORK_DIR/session_lib.sh"
sed 's/^readonly //; /^main "\$@"$/d' "$SESSION_SCRIPT" > "$TEST_SCRIPT"
# shellcheck source=/dev/null
source "$TEST_SCRIPT"

PROJECTS_DIR="$WORK_DIR/projects"
SESSION_CACHE_DIR="$WORK_DIR/cache"
mkdir -p "$PROJECTS_DIR/-Users-me-proj"

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
        echo "    Actual:   $actual"
    fi
}

title_record() {
    local sid=$1
    local title=$2
    jq -cn --arg sid "$sid" --arg t "$title" '{type: "custom-title", customTitle: $t, sessionId: $sid}'
}

message_record() {
    echo '{"type":"user","message":{"content":"mentions \"customTitle\":\"fake\" in text"}}'
}

readonly SID="11111111-2222-3333-4444-555555555555"
readonly TRANSCRIPT="$PROJECTS_DIR/-Users-me-proj/${SID}.jsonl"

echo "load_session_titles"

{
    message_record
    title_record "$SID" "first-name"
    message_record
    title_record "$SID" "first-name"
    title_record "$SID" "renamed-later"
    message_record
} > "$TRANSCRIPT"

assert_equals "last rename wins over the first title" \
    "$(load_session_titles "$SID")" "${SID}"$'\t'"renamed-later"

assert_equals "cached result is reused" \
    "$(load_session_titles "$SID")" "${SID}"$'\t'"renamed-later"

title_record "$SID" "renamed-again" >> "$TRANSCRIPT"
assert_equals "rename appended after a cached scan is picked up" \
    "$(load_session_titles "$SID")" "${SID}"$'\t'"renamed-again"

message_record >> "$TRANSCRIPT"
assert_equals "growth without a rename keeps the cached title" \
    "$(load_session_titles "$SID")" "${SID}"$'\t'"renamed-again"

title_record "$SID" "rewritten" > "$TRANSCRIPT"
assert_equals "shrunk transcript is rescanned from scratch" \
    "$(load_session_titles "$SID")" "${SID}"$'\t'"rewritten"

title_record "$SID" 'with "quotes" inside' > "$TRANSCRIPT"
assert_equals "escaped quotes in the title are decoded" \
    "$(load_session_titles "$SID")" "${SID}"$'\t''with "quotes" inside'

readonly UNTITLED_SID="99999999-2222-3333-4444-555555555555"
message_record > "$PROJECTS_DIR/-Users-me-proj/${UNTITLED_SID}.jsonl"
assert_equals "session without a title prints nothing" \
    "$(load_session_titles "$UNTITLED_SID")" ""

assert_equals "missing transcript prints nothing" \
    "$(load_session_titles "00000000-0000-0000-0000-000000000000")" ""

assert_equals "several sessions in one call" \
    "$(load_session_titles "${UNTITLED_SID},${SID}")" "${SID}"$'\t''with "quotes" inside'

echo ""
echo "Results: $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]]
