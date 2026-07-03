#!/bin/bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
LINKER="$SCRIPT_DIR/scripts/link-global-hooks.sh"
GLOBAL_COMMIT_MSG="$SCRIPT_DIR/scripts/git-hooks/commit-msg"
GLOBAL_POST_COMMIT="$SCRIPT_DIR/scripts/git-hooks/post-commit"

PASS=0
FAIL=0

WORK_DIR=$(mktemp -d)
FAKE_HOME="$WORK_DIR/home"
mkdir -p "$FAKE_HOME/.git-hooks"
cp "$GLOBAL_COMMIT_MSG" "$FAKE_HOME/.git-hooks/commit-msg"
cp "$GLOBAL_POST_COMMIT" "$FAKE_HOME/.git-hooks/post-commit"
chmod +x "$FAKE_HOME/.git-hooks/"*

cleanup() { rm -rf "$WORK_DIR"; }
trap cleanup EXIT

assert_equals() {
    local n=$1 a=$2 e=$3
    if [[ "$a" == "$e" ]]; then PASS=$((PASS+1)); echo "  PASS: $n"
    else FAIL=$((FAIL+1)); echo "  FAIL: $n"; echo "    Expected: $e"; echo "    Actual: $a"; fi
}
assert_contains() {
    local n=$1 a=$2 e=$3
    if echo "$a" | grep -qF "$e"; then PASS=$((PASS+1)); echo "  PASS: $n"
    else FAIL=$((FAIL+1)); echo "  FAIL: $n"; echo "    Expected to contain: $e"; echo "    Actual: $a"; fi
}
assert_not_contains() {
    local n=$1 a=$2 u=$3
    if echo "$a" | grep -qF "$u"; then FAIL=$((FAIL+1)); echo "  FAIL: $n"; echo "    Unexpected: $u"; echo "    Actual: $a"
    else PASS=$((PASS+1)); echo "  PASS: $n"; fi
}

# A repo shaped like multimedica: local .githooks with a Conventional-Commits
# commit-msg (that itself calls the global one) plus a side-effecting
# post-commit. HOME is faked so delegators resolve to our test global hooks.
new_repo_like_multimedica() {
    local dir="$WORK_DIR/$1"
    rm -rf "$dir"; mkdir -p "$dir/.githooks"
    git -C "$dir" init -q
    git -C "$dir" config user.email t@t.t
    git -C "$dir" config user.name t
    git -C "$dir" config commit.gpgsign false
    git -C "$dir" config core.hooksPath .githooks

    cat > "$dir/.githooks/commit-msg" <<'H'
#!/bin/sh
COMMIT_MSG_FILE=$1
GLOBAL_HOOK="$HOME/.git-hooks/commit-msg"
[ -x "$GLOBAL_HOOK" ] && "$GLOBAL_HOOK" "$COMMIT_MSG_FILE"
MSG=$(head -1 "$COMMIT_MSG_FILE")
echo "$MSG" | grep -qE '^(feat|fix|chore|docs|test|refactor|merge)(\(.+\))?: .+' || {
    echo "Bad format. Aborted."; exit 1; }
H
    cat > "$dir/.githooks/post-commit" <<'H'
#!/bin/sh
echo ran >> "$(git rev-parse --git-dir)/pc-marker"
H
    chmod +x "$dir/.githooks/commit-msg" "$dir/.githooks/post-commit"
    echo "$dir"
}

run_git() { env HOME="$FAKE_HOME" git -C "$1" "${@:2}"; }
msg_of() { run_git "$1" log -1 --format=%B; }

SIG='Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>'

echo "link-global-hooks tests"

R=$(new_repo_like_multimedica proj)
env HOME="$FAKE_HOME" /bin/bash "$LINKER" "$R" >/dev/null 2>&1

# Delegators and preserved project hooks are in place.
assert_contains "delegator marker in commit-msg" "$(cat "$R/.githooks/commit-msg")" "delegates to global hook"
assert_contains "preserved project commit-msg exists" "$(ls -a "$R/.githooks")" ".commit-msg.project"
assert_contains "preserved project post-commit exists" "$(ls -a "$R/.githooks")" ".post-commit.project"

# 1) Signed commit, valid Conventional format → signature stripped, one commit.
printf 'a\n' > "$R/f"; run_git "$R" add f
run_git "$R" commit -q -F - <<EOF
feat: add f

$SIG
EOF
assert_not_contains "valid commit: signature stripped" "$(msg_of "$R")" "noreply@anthropic.com"
assert_equals "valid commit: no double-amend" "$(run_git "$R" rev-list --count HEAD)" "1"

# 2) --no-verify bypasses commit-msg; post-commit delegator still cleans it.
printf 'b\n' >> "$R/f"; run_git "$R" add f
run_git "$R" commit -q --no-verify -F - <<EOF
fix: bypass

$SIG
EOF
assert_not_contains "no-verify: signature stripped via post-commit" "$(msg_of "$R")" "noreply@anthropic.com"
assert_equals "no-verify: no double-amend" "$(run_git "$R" rev-list --count HEAD)" "2"

# 3) Project post-commit side effect runs exactly once (not re-fired by amend).
marker_count=$(grep -c ran "$R/.git/pc-marker")
# two commits so far, each should have run the project hook exactly once → 2
assert_equals "project post-commit ran once per commit" "$marker_count" "2"

# 4) Project's Conventional-Commits validation still enforced.
printf 'c\n' >> "$R/f"; run_git "$R" add f
if run_git "$R" commit -q -m "bad message" 2>/dev/null; then
    FAIL=$((FAIL+1)); echo "  FAIL: bad format should be rejected"
else
    PASS=$((PASS+1)); echo "  PASS: bad format rejected by project hook"
fi

# 5) Re-running the linker is idempotent (no nested preservation).
env HOME="$FAKE_HOME" /bin/bash "$LINKER" "$R" >/dev/null 2>&1
assert_contains "rerun: commit-msg still a delegator" "$(cat "$R/.githooks/commit-msg")" "delegates to global hook"
# The preserved project hook must still be the ORIGINAL, not a delegator.
assert_not_contains "rerun: preserved hook not overwritten by delegator" "$(cat "$R/.githooks/.commit-msg.project")" "delegates to global hook"

echo
echo "Passed: $PASS, Failed: $FAIL"
[[ $FAIL -eq 0 ]]
