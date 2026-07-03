#!/bin/bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
HOOK="$SCRIPT_DIR/scripts/git-hooks/commit-msg"

PASS=0
FAIL=0

WORK_DIR=$(mktemp -d)

cleanup() {
    rm -rf "$WORK_DIR"
}
trap cleanup EXIT

assert_not_contains() {
    local test_name=$1
    local actual=$2
    local unexpected=$3

    if echo "$actual" | grep -qF "$unexpected"; then
        FAIL=$((FAIL + 1))
        echo "  FAIL: $test_name"
        echo "    Unexpected substring present: $unexpected"
        echo "    Actual: $actual"
    else
        PASS=$((PASS + 1))
        echo "  PASS: $test_name"
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

# Fresh repo wired to the hook under test, isolated from the user's config.
new_repo() {
    local dir="$WORK_DIR/$1"
    rm -rf "$dir"; mkdir -p "$dir/hooks"
    cp "$HOOK" "$dir/hooks/commit-msg"
    chmod +x "$dir/hooks/commit-msg"
    git -C "$dir" init -q
    git -C "$dir" config core.hooksPath "$dir/hooks"
    git -C "$dir" config user.email t@t.t
    git -C "$dir" config user.name t
    git -C "$dir" config commit.gpgsign false
    echo "$dir"
}

commit_msg() {
    git -C "$1" log -1 --format=%B
}

SIG='Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>'
GEN='🤖 Generated with [Claude Code](https://claude.com/claude-code)'

echo "commit-msg hook tests"

# --- Ordinary commit strips the signature ---
R=$(new_repo plain)
printf 'a\n' > "$R/f"; git -C "$R" add f
git -C "$R" commit -q -F - <<EOF
feat: add f

$SIG
EOF
msg=$(commit_msg "$R")
assert_contains "plain commit: keeps subject" "$msg" "feat: add f"
assert_not_contains "plain commit: strips Co-Authored-By" "$msg" "$SIG"

# --- The 1M-context / model-name variant (the reported merch case) ---
R=$(new_repo merch)
printf 'a\n' > "$R/f"; git -C "$R" add f
git -C "$R" commit -q -F - <<EOF
merged composer.json.

composer analyze: no errors.

$SIG
EOF
msg=$(commit_msg "$R")
assert_contains "merch commit: keeps body" "$msg" "composer analyze"
assert_not_contains "merch commit: strips 1M-context signature" "$msg" "noreply@anthropic.com"

# --- Generated-with footer stripped ---
R=$(new_repo generated)
printf 'a\n' > "$R/f"; git -C "$R" add f
git -C "$R" commit -q -F - <<EOF
feat: thing

$GEN

$SIG
EOF
msg=$(commit_msg "$R")
assert_not_contains "generated footer stripped" "$msg" "Generated with"
assert_not_contains "generated: signature also stripped" "$msg" "noreply@anthropic.com"

# --- Case / spacing variations still caught ---
R=$(new_repo variants)
printf 'a\n' > "$R/f"; git -C "$R" add f
git -C "$R" commit -q -F - <<'EOF'
feat: variants

co-authored-by:  Some Model   <noreply@anthropic.com>
EOF
msg=$(commit_msg "$R")
assert_not_contains "lowercase + extra spaces still stripped" "$msg" "noreply@anthropic.com"

# --- Merge commit with -m also gets cleaned ---
R=$(new_repo merge)
printf 'base\n' > "$R/f"; git -C "$R" add f; git -C "$R" commit -q -m init
git -C "$R" checkout -q -b feature
printf 'feat\n' > "$R/g"; git -C "$R" add g; git -C "$R" commit -q -m feat
git -C "$R" checkout -q main
printf 'main\n' > "$R/h"; git -C "$R" add h; git -C "$R" commit -q -m main
git -C "$R" merge --no-edit -m "Merge feature

$SIG" feature >/dev/null 2>&1
msg=$(commit_msg "$R")
assert_contains "merge commit: keeps subject" "$msg" "Merge feature"
assert_not_contains "merge commit: strips signature" "$msg" "$SIG"

# --- Merge with conflict, resolved by hand, then committed ---
R=$(new_repo conflict)
printf 'base\n' > "$R/f"; git -C "$R" add f; git -C "$R" commit -q -m init
git -C "$R" checkout -q -b feature
printf 'feature\n' > "$R/f"; git -C "$R" add f; git -C "$R" commit -q -m feat
git -C "$R" checkout -q main
printf 'main\n' > "$R/f"; git -C "$R" add f; git -C "$R" commit -q -m main
git -C "$R" merge --no-edit feature >/dev/null 2>&1 || true
printf 'resolved\n' > "$R/f"; git -C "$R" add f
git -C "$R" commit -q -F - <<EOF
merged composer.json.

$SIG
EOF
msg=$(commit_msg "$R")
assert_contains "conflict resolve: keeps body" "$msg" "merged composer.json"
assert_not_contains "conflict resolve: strips signature" "$msg" "$SIG"

# --- --no-verify bypasses commit-msg entirely (by git design). This is the path
# that let the signature slip into the real merch commits. commit-msg alone
# cannot catch it — the post-commit hook covers this case instead (see
# post_commit_hook_test.sh). Here we only document that commit-msg is bypassed.
R=$(new_repo noverify)
printf 'a\n' > "$R/f"; git -C "$R" add f
git -C "$R" commit -q --no-verify -F - <<EOF
merged composer.json.

$SIG
EOF
msg=$(commit_msg "$R")
assert_contains "no-verify: signature survives (documents the gap)" "$msg" "noreply@anthropic.com"

echo
echo "Passed: $PASS, Failed: $FAIL"
[[ $FAIL -eq 0 ]]
