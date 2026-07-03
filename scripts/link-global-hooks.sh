#!/bin/bash

set -euo pipefail

# Wire a project's local hooks directory to the global Claude hooks.
#
# Projects that set `core.hooksPath` locally (e.g. `.githooks`) bypass the
# global `~/.git-hooks` entirely — git honours only one hooksPath. This script
# drops a thin delegator into that local directory for each global hook, so the
# signature-cleaning hooks (commit-msg, post-commit) run there too.
#
# A delegator calls the global hook first, then, if a project-owned hook with
# the same name already existed, runs that afterwards — so existing local logic
# (conventional-commits validation, composer checks, …) keeps working.
#
# Usage:
#   scripts/link-global-hooks.sh [PROJECT_DIR]   (default: current directory)

readonly GLOBAL_HOOKS_DIR="$HOME/.git-hooks"
readonly DELEGATED_HOOKS=(commit-msg post-commit)

readonly COLOR_GREEN="\033[32m"
readonly COLOR_YELLOW="\033[33m"
readonly COLOR_RED="\033[31m"
readonly COLOR_BLUE="\033[34m"
readonly COLOR_RESET="\033[0m"

log_info()    { echo -e "${COLOR_BLUE}[INFO]${COLOR_RESET} $1"; }
log_success() { echo -e "${COLOR_GREEN}[OK]${COLOR_RESET} $1"; }
log_warning() { echo -e "${COLOR_YELLOW}[WARN]${COLOR_RESET} $1"; }
log_error()   { echo -e "${COLOR_RED}[ERROR]${COLOR_RESET} $1"; }

project_dir="${1:-$(pwd)}"

if ! git -C "$project_dir" rev-parse --git-dir >/dev/null 2>&1; then
    log_error "Not a git repository: $project_dir"
    exit 1
fi

hooks_path=$(git -C "$project_dir" config --get core.hooksPath 2>/dev/null || true)

if [[ -z "$hooks_path" ]]; then
    log_warning "No local core.hooksPath in $project_dir — global hooks already apply. Nothing to do."
    exit 0
fi

if [[ "$hooks_path" == "$GLOBAL_HOOKS_DIR" ]]; then
    log_warning "core.hooksPath already points at the global hooks dir. Nothing to do."
    exit 0
fi

# Resolve hooksPath relative to the repo working tree, like git does.
if [[ "$hooks_path" = /* ]]; then
    local_hooks_dir="$hooks_path"
else
    toplevel=$(git -C "$project_dir" rev-parse --show-toplevel)
    local_hooks_dir="$toplevel/$hooks_path"
fi

log_info "Local hooks dir: $local_hooks_dir"
mkdir -p "$local_hooks_dir"

for hook in "${DELEGATED_HOOKS[@]}"; do
    global_hook="$GLOBAL_HOOKS_DIR/$hook"
    if [[ ! -x "$global_hook" ]]; then
        log_warning "Global hook not installed, skipping: $global_hook"
        continue
    fi

    target="$local_hooks_dir/$hook"

    # A delegator we wrote before carries this marker — safe to overwrite.
    marker="# claude-tools: delegates to global hook"

    if [[ -e "$target" ]] && ! grep -qF "$marker" "$target" 2>/dev/null; then
        # A real project-owned hook is here. Preserve it: the delegator will
        # run it after the global one. Move it aside once.
        preserved="$local_hooks_dir/.${hook}.project"
        if [[ ! -e "$preserved" ]]; then
            cp "$target" "$preserved"
            chmod +x "$preserved"
            log_info "Preserved existing project hook → $(basename "$preserved")"
        fi
    fi

    # Ordering differs by hook kind:
    #  - commit-msg edits the message *before* the commit is written, so clean
    #    globally first, then let the project hook validate the cleaned text.
    #  - post-commit runs *after* the commit and the global one amends in place,
    #    which re-fires post-commit. So run the project hook FIRST (on the
    #    original commit, once), then clean. The global CLAUDE_SIG_STRIP guard is
    #    re-exported here so the project hook is not re-run during our amend.
    if [[ "$hook" == "post-commit" ]]; then
        cat > "$target" <<DELEGATOR
#!/bin/sh
$marker — runs any project-owned hook, then cleans Claude signatures.

# Our own amend re-fires post-commit; skip everything on that pass.
[ -n "\$CLAUDE_SIG_STRIP" ] && exit 0

PROJECT_HOOK="\$(dirname "\$0")/.${hook}.project"
[ -x "\$PROJECT_HOOK" ] && "\$PROJECT_HOOK" "\$@"

GLOBAL_HOOK="\$HOME/.git-hooks/$hook"
[ -x "\$GLOBAL_HOOK" ] && exec "\$GLOBAL_HOOK" "\$@"

exit 0
DELEGATOR
    else
        cat > "$target" <<DELEGATOR
#!/bin/sh
$marker — cleans Claude signatures, then runs any project-owned hook.

GLOBAL_HOOK="\$HOME/.git-hooks/$hook"
[ -x "\$GLOBAL_HOOK" ] && "\$GLOBAL_HOOK" "\$@"

PROJECT_HOOK="\$(dirname "\$0")/.${hook}.project"
[ -x "\$PROJECT_HOOK" ] && exec "\$PROJECT_HOOK" "\$@"

exit 0
DELEGATOR
    fi
    chmod +x "$target"
    log_success "Wired: $target → global $hook"
done

log_success "Done. Local hooks now delegate to global Claude hooks."
