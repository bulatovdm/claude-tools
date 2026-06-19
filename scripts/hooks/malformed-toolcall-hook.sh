#!/bin/bash

set -euo pipefail

readonly SCRIPT_NAME=$(basename "$0")
readonly SOURCE_HOOK="$(cd "$(dirname "$0")" && pwd)/check-malformed-toolcall.sh"
readonly CLAUDE_DIR="$HOME/.claude"
readonly HOOKS_TARGET_DIR="$CLAUDE_DIR/hooks"
readonly INSTALLED_HOOK="$HOOKS_TARGET_DIR/check-malformed-toolcall.sh"
readonly SETTINGS_FILE="$CLAUDE_DIR/settings.json"
readonly HOOK_COMMAND="~/.claude/hooks/check-malformed-toolcall.sh"

readonly COLOR_GREEN="\033[32m"
readonly COLOR_YELLOW="\033[33m"
readonly COLOR_RED="\033[31m"
readonly COLOR_RESET="\033[0m"

log_success() {
    echo -e "${COLOR_GREEN}✓${COLOR_RESET} $1"
}

log_warning() {
    echo -e "${COLOR_YELLOW}!${COLOR_RESET} $1"
}

die() {
    echo -e "${COLOR_RED}✗${COLOR_RESET} $1" >&2
    exit 1
}

require_dependencies() {
    command -v jq &> /dev/null || die "jq is required but not installed"
    [[ -f "$SOURCE_HOOK" ]] || die "Hook script not found: $SOURCE_HOOK"
}

is_registered() {
    [[ -f "$SETTINGS_FILE" ]] || return 1
    local count
    count=$(jq --arg cmd "$HOOK_COMMAND" \
        '[.hooks.Stop[]?.hooks[]? | select(.command == $cmd)] | length' \
        "$SETTINGS_FILE" 2>/dev/null || echo 0)
    [[ "$count" != "0" ]]
}

install_hook_script() {
    mkdir -p "$HOOKS_TARGET_DIR"
    cp "$SOURCE_HOOK" "$INSTALLED_HOOK"
    chmod +x "$INSTALLED_HOOK"
    log_success "Installed: $INSTALLED_HOOK"
}

register_in_settings() {
    [[ -f "$SETTINGS_FILE" ]] || echo '{}' > "$SETTINGS_FILE"

    jq --arg cmd "$HOOK_COMMAND" \
        '.hooks.Stop += [{"matcher": "", "hooks": [{"type": "command", "command": $cmd}]}]' \
        "$SETTINGS_FILE" > "${SETTINGS_FILE}.tmp"
    mv "${SETTINGS_FILE}.tmp" "$SETTINGS_FILE"
    log_success "Registered Stop hook in settings.json"
}

unregister_from_settings() {
    [[ -f "$SETTINGS_FILE" ]] || return 0

    jq --arg cmd "$HOOK_COMMAND" \
        '(.hooks.Stop) |= (map(.hooks |= map(select(.command != $cmd))) | map(select(.hooks | length > 0)))
         | if (.hooks.Stop | length) == 0 then del(.hooks.Stop) else . end' \
        "$SETTINGS_FILE" > "${SETTINGS_FILE}.tmp"
    mv "${SETTINGS_FILE}.tmp" "$SETTINGS_FILE"
    log_success "Removed Stop hook from settings.json"
}

enable_hook() {
    require_dependencies

    if is_registered; then
        log_warning "Hook already enabled"
        return 0
    fi

    install_hook_script
    register_in_settings
    log_success "Stop hook enabled"
}

disable_hook() {
    require_dependencies

    if ! is_registered; then
        log_warning "Hook is not enabled"
        return 0
    fi

    unregister_from_settings
    log_success "Stop hook disabled"
}

show_status() {
    if is_registered; then
        log_success "Stop hook is ENABLED"
    else
        log_warning "Stop hook is DISABLED"
    fi
}

show_help() {
    cat <<EOF
Usage: $SCRIPT_NAME <command>

Enable or disable the malformed tool-call Stop hook for Claude Code.

Commands:
    enable      Install the hook and register it in ~/.claude/settings.json
    disable     Remove the hook from ~/.claude/settings.json
    status      Show whether the hook is currently enabled
    help        Show this help message
EOF
}

main() {
    local command=${1:-help}

    case "$command" in
        enable) enable_hook ;;
        disable) disable_hook ;;
        status) show_status ;;
        help | -h | --help) show_help ;;
        *) die "Unknown command: $command (run '$SCRIPT_NAME help')" ;;
    esac
}

main "$@"
