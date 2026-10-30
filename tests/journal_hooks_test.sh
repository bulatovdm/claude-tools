#!/bin/bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
HOOKS_DIR="$SCRIPT_DIR/.claude/hooks"

PASS=0
FAIL=0

WORK_DIR=$(mktemp -d)
REPO="$WORK_DIR/repo"
TODAY=$(date +%F)
JOURNAL="$REPO/knowledge/journal/$TODAY-01.md"

export JOURNAL_REPOSITORY_ROOT="$REPO"
export TMPDIR="$WORK_DIR/tmp"
mkdir -p "$TMPDIR"

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

run_hook() {
    local hook=$1
    local input=$2
    local status=0
    HOOK_OUTPUT=$(printf '%s' "$input" | /bin/bash "$HOOKS_DIR/$hook" 2>&1) || status=$?
    HOOK_STATUS=$status
}

commit_input() {
    jq -cn --arg command "$1" '{tool_input: {command: $command}}'
}

repo_git() {
    git -C "$REPO" -c user.name=test -c user.email=test@example.com -c core.hooksPath=/dev/null "$@"
}

fill_journal() {
    sed -i '' '/НЕ ЗАПОЛНЕН/d' "$JOURNAL"
    echo "- $1" >> "$JOURNAL"
}

mkdir -p "$REPO"
repo_git init -q
echo "seed" > "$REPO/file.txt"
repo_git add file.txt
repo_git commit -q -m "seed"

echo "=== journal hooks tests ==="
echo ""

echo "[session-start]"

run_hook session-start.sh '{}'
assert_equals "creates today's journal" "$([[ -f "$JOURNAL" ]] && echo yes)" "yes"
assert_contains "points to the journal" "$HOOK_OUTPUT" "ЖУРНАЛ ЭТОЙ СЕССИИ: knowledge/journal/$TODAY-01.md"
assert_contains "new journal is reported unfilled" "$HOOK_OUTPUT" "ещё не заполнен"
assert_contains "journal carries the marker" "$(cat "$JOURNAL")" "<!-- НЕ ЗАПОЛНЕН -->"
assert_contains "journal is titled by its name" "$(head -1 "$JOURNAL")" "# $TODAY-01"
assert_contains "prints the protocol" "$HOOK_OUTPUT" "ПРОТОКОЛ ЖУРНАЛА"

echo "- prior" > "$REPO/knowledge/journal/2000-01-01-01.md"
fill_journal "first step"
run_hook session-start.sh '{}'
assert_contains "filled journal is continued, not reset" "$(cat "$JOURNAL")" "first step"
assert_contains "filled journal is reported in progress" "$HOOK_OUTPUT" "уже заполняется"
assert_contains "lists previous journals" "$HOOK_OUTPUT" "knowledge/journal/2000-01-01-01.md"
assert_equals "current journal is not listed as previous" "$(grep -c "  knowledge/journal/$TODAY-01.md" <<< "$HOOK_OUTPUT" || true)" "0"

echo ""
echo "[guard-commit]"

rm -f "$JOURNAL"
run_hook session-start.sh '{}'

run_hook guard-commit.sh "$(commit_input 'ls -la')"
assert_equals "non-commit command passes" "$HOOK_STATUS" "0"

run_hook guard-commit.sh "$(commit_input 'git commit -m "x"')"
assert_equals "commit with unfilled journal is blocked" "$HOOK_STATUS" "2"
assert_contains "block names the journal" "$HOOK_OUTPUT" "knowledge/journal/$TODAY-01.md не заполнен"

run_hook guard-commit.sh "$(commit_input 'git add -A && git -C /tmp commit -m "x"')"
assert_equals "chained commit with -C is recognised" "$HOOK_STATUS" "2"

run_hook guard-commit.sh "$(commit_input 'git commit-tree abc')"
assert_equals "commit-tree is not a commit" "$HOOK_STATUS" "0"

heredoc_with_commit_text=$'cat > notes.txt <<\'EOF\'\nthen run git commit -m done\nEOF'
run_hook guard-commit.sh "$(commit_input "$heredoc_with_commit_text")"
assert_equals "commit text inside a heredoc is data" "$HOOK_STATUS" "0"

heredoc_then_commit=$'cat > notes.txt <<EOF\ntext\nEOF\ngit commit -m done'
run_hook guard-commit.sh "$(commit_input "$heredoc_then_commit")"
assert_equals "commit after the heredoc ends is caught" "$HOOK_STATUS" "2"

run_hook guard-commit.sh "$(commit_input 'cat <<< "x"; git commit -m done')"
assert_equals "here-string is not mistaken for a heredoc" "$HOOK_STATUS" "2"

fill_journal "did a thing"
run_hook guard-commit.sh "$(commit_input 'git commit -m "x"')"
assert_equals "filled untracked journal allows commit" "$HOOK_STATUS" "0"

repo_git add -A
repo_git commit -q -m "with journal"
run_hook guard-commit.sh "$(commit_input 'git commit -m "y"')"
assert_equals "journal untouched since last commit blocks" "$HOOK_STATUS" "2"
assert_contains "block explains the untouched journal" "$HOOK_OUTPUT" "не менялся с прошлого коммита"

echo "- next step" >> "$JOURNAL"
run_hook guard-commit.sh "$(commit_input 'git commit -m "y"')"
assert_equals "new journal line allows the next commit" "$HOOK_STATUS" "0"

echo ""
echo "[guard-stop]"

rm -f "$JOURNAL"
run_hook session-start.sh '{}'
repo_git add -A
repo_git commit -q -m "fresh journal"

run_hook guard-stop.sh '{"session_id":"s1"}'
assert_equals "clean tree with empty journal may stop" "$HOOK_STATUS" "0"

echo "change" >> "$REPO/file.txt"
run_hook guard-stop.sh '{"session_id":"s1"}'
assert_equals "uncommitted work with empty journal blocks stop" "$HOOK_STATUS" "2"
assert_contains "stop block names the journal" "$HOOK_OUTPUT" "knowledge/journal/$TODAY-01.md пуст"

run_hook guard-stop.sh '{"session_id":"s1"}'
assert_equals "stop is blocked only once per session" "$HOOK_STATUS" "0"

run_hook guard-stop.sh '{"session_id":"s2","stop_hook_active":true}'
assert_equals "active stop hook never loops" "$HOOK_STATUS" "0"

fill_journal "wrote it down"
run_hook guard-stop.sh '{"session_id":"s3"}'
assert_equals "filled journal lets the session stop" "$HOOK_STATUS" "0"

echo ""
echo "========================"
TOTAL=$((PASS + FAIL))
echo "Results: $PASS/$TOTAL passed"
if (( FAIL > 0 )); then
    echo "$FAIL test(s) FAILED"
    exit 1
fi
echo "All tests passed!"
