#!/bin/bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
HOOK="$SCRIPT_DIR/scripts/git-hooks/post-commit"

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

# Fresh repo wired ONLY to the post-commit hook (commit-msg deliberately absent,
# so these tests isolate what post-commit does — including the --no-verify path).
new_repo() {
    local dir="$WORK_DIR/$1"
    rm -rf "$dir"; mkdir -p "$dir/hooks"
    cp "$HOOK" "$dir/hooks/post-commit"
    chmod +x "$dir/hooks/post-commit"
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

echo "post-commit hook tests"

# --- Plain commit: signature stripped by post-commit's amend ---
R=$(new_repo plain)
printf 'a\n' > "$R/f"; git -C "$R" add f
git -C "$R" commit -q -F - <<EOF
feat: add f

body line

$SIG
EOF
msg=$(commit_msg "$R")
assert_contains "plain: keeps subject" "$msg" "feat: add f"
assert_contains "plain: keeps body" "$msg" "body line"
assert_not_contains "plain: strips signature" "$msg" "noreply@anthropic.com"

# --- THE KEY CASE: --no-verify. commit-msg is bypassed; post-commit still cleans it ---
R=$(new_repo noverify)
printf 'a\n' > "$R/f"; git -C "$R" add f
git -C "$R" commit -q --no-verify -F - <<EOF
fix: bypass hooks

$SIG
EOF
msg=$(commit_msg "$R")
assert_contains "no-verify: keeps subject" "$msg" "fix: bypass hooks"
assert_not_contains "no-verify: strips signature (the closed gap)" "$msg" "noreply@anthropic.com"

# --- No signature: no needless amend, no recursion, history intact ---
R=$(new_repo clean)
printf 'a\n' > "$R/f"; git -C "$R" add f; git -C "$R" commit -q -m init
printf 'b\n' >> "$R/f"; git -C "$R" add f
git -C "$R" commit -q -m "chore: clean commit"
count=$(git -C "$R" rev-list --count HEAD)
assert_equals "clean: no extra commits from recursion" "$count" "2"
assert_contains "clean: message untouched" "$(commit_msg "$R")" "chore: clean commit"

# --- Merge with conflict, resolved by hand, committed with --no-verify ---
R=$(new_repo conflict)
printf 'base\n' > "$R/f"; git -C "$R" add f; git -C "$R" commit -q -m init
git -C "$R" checkout -q -b feature
printf 'feature\n' > "$R/f"; git -C "$R" add f; git -C "$R" commit -q -m feat
git -C "$R" checkout -q main
printf 'main\n' > "$R/f"; git -C "$R" add f; git -C "$R" commit -q -m main
git -C "$R" merge --no-edit feature >/dev/null 2>&1 || true
printf 'resolved\n' > "$R/f"; git -C "$R" add f
git -C "$R" commit -q --no-verify -F - <<EOF
fix: resolve merge

$SIG
EOF
msg=$(commit_msg "$R")
assert_contains "conflict merge: keeps subject" "$msg" "fix: resolve merge"
assert_not_contains "conflict merge: strips signature" "$msg" "noreply@anthropic.com"
parents=$(git -C "$R" log -1 --format='%P' | wc -w | tr -d ' ')
assert_equals "conflict merge: merge structure preserved (2 parents)" "$parents" "2"

# --- KNOWN LIMITATION: a clean (conflict-free) merge is NOT handled by
# post-commit — git skips post-commit for auto-created merge commits, and
# amending is impossible while MERGE_HEAD is set. commit-msg covers that path
# instead (except the rare `git merge --no-verify`). Documented, not asserted
# as cleaned, so the boundary is explicit.
R=$(new_repo cleanmerge)
printf 'base\n' > "$R/f"; git -C "$R" add f; git -C "$R" commit -q -m init
git -C "$R" checkout -q -b feature
printf 'x\n' > "$R/g"; git -C "$R" add g; git -C "$R" commit -q -m feat
git -C "$R" checkout -q main
printf 'y\n' > "$R/h"; git -C "$R" add h; git -C "$R" commit -q -m main
git -C "$R" merge --no-edit -m "Merge feature

$SIG" feature >/dev/null 2>&1
msg=$(commit_msg "$R")
assert_contains "clean merge: post-commit does NOT touch it (by design)" "$msg" "noreply@anthropic.com"

echo
echo "Passed: $PASS, Failed: $FAIL"
[[ $FAIL -eq 0 ]]
