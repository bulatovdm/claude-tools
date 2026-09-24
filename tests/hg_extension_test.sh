#!/bin/bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
EXTENSION="$SCRIPT_DIR/scripts/hg-extensions/strip_claude_signature.py"

PASS=0
FAIL=0

if ! command -v hg &> /dev/null; then
    echo "hg extension tests: Mercurial not installed — skipped"
    exit 0
fi

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

# Only this file is read as config, so the user's ~/.hgrc never leaks in.
export HGRCPATH="$WORK_DIR/hgrc"
export HGPLAIN=1
printf '[ui]\nusername = t <t@t.t>\n[extensions]\nstrip_claude_signature = %s\n' "$EXTENSION" > "$HGRCPATH"

new_repo() {
    local dir="$WORK_DIR/$1"
    hg init "$dir"
    printf 'a\n' > "$dir/f"
    hg -R "$dir" add -q "$dir/f"
    echo "$dir"
}

touch_file() {
    printf 'x\n' >> "$1/f"
}

commit_msg() {
    hg -R "$1" log -r . --template '{desc}'
}

SIG='Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>'
GEN='🤖 Generated with [Claude Code](https://claude.com/claude-code)'

echo "hg extension tests"

# --- Ordinary commit strips the signature, keeps body and task link ---
R=$(new_repo plain)
hg -R "$R" commit -q -m "$(printf 'fix: add f\n\nbody\n\nhttps://hubhead.app/x\n\n%s' "$SIG")"
msg=$(commit_msg "$R")
assert_contains "plain commit: keeps subject" "$msg" "fix: add f"
assert_contains "plain commit: keeps task link" "$msg" "https://hubhead.app/x"
assert_not_contains "plain commit: strips Co-Authored-By" "$msg" "noreply@anthropic.com"

# --- Generated-with footer and lowercase variant ---
R=$(new_repo generated)
hg -R "$R" commit -q -m "$(printf 'feat: thing\n\n%s\n\nco-authored-by:  Some Model   <noreply@anthropic.com>\n' "$GEN")"
msg=$(commit_msg "$R")
assert_not_contains "generated footer stripped" "$msg" "Generated with"
assert_not_contains "lowercase + extra spaces still stripped" "$msg" "noreply@anthropic.com"
assert_contains "generated: nothing but subject left" "$msg" "feat: thing"

# --- Human co-author is not touched ---
R=$(new_repo human)
hg -R "$R" commit -q -m "$(printf 'chore: pair work\n\nCo-Authored-By: Ivan <ivan@example.com>')"
msg=$(commit_msg "$R")
assert_contains "human co-author kept" "$msg" "Co-Authored-By: Ivan <ivan@example.com>"

# --- Amend goes through the same path ---
R=$(new_repo amend)
hg -R "$R" commit -q -m "chore: before amend"
touch_file "$R"
hg -R "$R" commit -q --amend -m "$(printf 'chore: after amend\n\n%s' "$SIG")"
msg=$(commit_msg "$R")
assert_contains "amend: new subject" "$msg" "chore: after amend"
assert_not_contains "amend: strips signature" "$msg" "noreply@anthropic.com"

# --- Message typed in the editor, not passed with -m ---
R=$(new_repo editor)
EDITOR_SCRIPT="$WORK_DIR/editor.sh"
printf '#!/bin/sh\nprintf "fix: from editor\\n\\n%s\\n" > "$1"\n' "$SIG" > "$EDITOR_SCRIPT"
chmod +x "$EDITOR_SCRIPT"
HGEDITOR="$EDITOR_SCRIPT" hg -R "$R" commit -q
msg=$(commit_msg "$R")
assert_contains "editor: keeps subject" "$msg" "fix: from editor"
assert_not_contains "editor: strips signature" "$msg" "noreply@anthropic.com"

# --- Control: without the extension the signature survives, so the tests above are real ---
printf '[ui]\nusername = t <t@t.t>\n' > "$HGRCPATH"
R=$(new_repo control)
hg -R "$R" commit -q -m "$(printf 'test: control\n\n%s' "$SIG")"
msg=$(commit_msg "$R")
assert_contains "control: signature kept without extension" "$msg" "noreply@anthropic.com"

echo
echo "Passed: $PASS, Failed: $FAIL"
[[ $FAIL -eq 0 ]]
