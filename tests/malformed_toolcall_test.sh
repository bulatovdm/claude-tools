#!/bin/bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
HOOK="$SCRIPT_DIR/scripts/hooks/check-malformed-toolcall.sh"

PASS=0
FAIL=0

WORK_DIR=$(mktemp -d)

cleanup() {
    rm -rf "$WORK_DIR"
}
trap cleanup EXIT

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

    if echo "$actual" | grep -qF "$expected"; then
        PASS=$((PASS + 1))
        echo "  PASS: $test_name"
    else
        FAIL=$((FAIL + 1))
        echo "  FAIL: $test_name"
        echo "    Expected to contain: $expected"
        echo "    Actual: $actual"
    fi
}

raw_marker() {
    printf '</%s>' "para""meter"
}

write_transcript() {
    local file=$1
    local last_text=$2
    : > "$file"
    printf '{"type":"user","message":{"content":"hi"}}\n' >> "$file"
    python3 - "$file" "$last_text" <<'PY'
import json, sys
path, text = sys.argv[1], sys.argv[2]
entry = {"type": "assistant", "message": {"content": [{"type": "text", "text": text}]}}
with open(path, "a") as f:
    f.write(json.dumps(entry) + "\n")
PY
}

run_hook() {
    local transcript=$1
    local session=$2
    printf '{"session_id":"%s","transcript_path":"%s"}' "$session" "$transcript" \
        | env HOME="$WORK_DIR" /bin/bash "$HOOK" 2>"$WORK_DIR/stderr"
}

attempt_file() {
    echo "$WORK_DIR/.claude/.malformed-toolcall-attempts/$1"
}

echo "Running malformed tool-call hook tests..."

MALFORMED="$WORK_DIR/malformed.jsonl"
CLEAN="$WORK_DIR/clean.jsonl"
write_transcript "$MALFORMED" "some text $(raw_marker)"
write_transcript "$CLEAN" "a perfectly normal final message"

echo
echo "Test: clean transcript produces no block"
out=$(run_hook "$CLEAN" "sess-clean")
assert_equals "clean → empty stdout" "$out" ""

echo
echo "Test: malformed transcript blocks on first three attempts"
rm -f "$(attempt_file sess-block)"
for n in 1 2 3; do
    out=$(run_hook "$MALFORMED" "sess-block")
    dec=$(echo "$out" | jq -r '.decision // "none"')
    assert_equals "attempt $n → block" "$dec" "block"
    assert_contains "attempt $n → retry counter" "$out" "retry $n/3"
done

echo
echo "Test: fourth attempt gives up (no block, stderr warning)"
out=$(run_hook "$MALFORMED" "sess-block")
assert_equals "attempt 4 → no block" "$out" ""
assert_contains "attempt 4 → stderr warns" "$(cat "$WORK_DIR/stderr")" "persisted after 3 retries"

echo
echo "Test: counter resets after a clean turn"
rm -f "$(attempt_file sess-reset)"
run_hook "$MALFORMED" "sess-reset" >/dev/null
run_hook "$MALFORMED" "sess-reset" >/dev/null
run_hook "$CLEAN" "sess-reset" >/dev/null
assert_equals "clean removes attempt file" "$([[ -f "$(attempt_file sess-reset)" ]] && echo exists || echo gone)" "gone"
out=$(run_hook "$MALFORMED" "sess-reset")
assert_contains "after reset → retry 1/3 again" "$out" "retry 1/3"

echo
echo "Test: per-session counters are independent"
rm -f "$(attempt_file sess-a)" "$(attempt_file sess-b)"
run_hook "$MALFORMED" "sess-a" >/dev/null
run_hook "$MALFORMED" "sess-a" >/dev/null
out=$(run_hook "$MALFORMED" "sess-b")
assert_contains "sess-b starts fresh at 1/3" "$out" "retry 1/3"

echo
echo "Test: disable flag suppresses the hook entirely"
mkdir -p "$WORK_DIR/.claude"
touch "$WORK_DIR/.claude/.disable-malformed-toolcall-hook"
out=$(run_hook "$MALFORMED" "sess-disabled")
assert_equals "disabled → empty stdout" "$out" ""
rm -f "$WORK_DIR/.disable-malformed-toolcall-hook"

echo
echo "Test: missing transcript path is a no-op"
out=$(printf '{"session_id":"x","transcript_path":""}' | env HOME="$WORK_DIR" /bin/bash "$HOOK" 2>&1)
assert_equals "missing transcript → empty" "$out" ""

echo
echo "Results: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
