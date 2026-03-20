#!/bin/bash

set -euo pipefail

readonly SCRIPT_NAME=$(basename "$0")
readonly VERSION="1.0.0"
readonly CLAUDE_DIR="$HOME/.claude"
readonly SCRIPTS_DIR="$(cd "$(dirname "$0")" && pwd)/scripts"
readonly HOOKS_DIR="$SCRIPTS_DIR/hooks"
readonly GIT_HOOKS_DIR="$SCRIPTS_DIR/git-hooks"
readonly GIT_HOOKS_TARGET="$HOME/.git-hooks"

readonly COLOR_GREEN="\033[32m"
readonly COLOR_YELLOW="\033[33m"
readonly COLOR_RED="\033[31m"
readonly COLOR_BLUE="\033[34m"
readonly COLOR_RESET="\033[0m"

show_help() {
    cat << EOF
Usage: $SCRIPT_NAME [OPTIONS] [COMMAND]

Installer for Claude Code tools.

Commands:
    install         Install all tools (default)
    uninstall       Remove installed tools
    status          Check installation status

Options:
    -h, --help      Show this help message
    -v, --version   Show version
    -f, --force     Overwrite existing files

Examples:
    $SCRIPT_NAME
    $SCRIPT_NAME install
    $SCRIPT_NAME install --force
    $SCRIPT_NAME uninstall
    $SCRIPT_NAME status

EOF
}

show_version() {
    echo "$SCRIPT_NAME version $VERSION"
}

log_info() {
    echo -e "${COLOR_BLUE}[INFO]${COLOR_RESET} $1"
}

log_success() {
    echo -e "${COLOR_GREEN}[OK]${COLOR_RESET} $1"
}

log_warning() {
    echo -e "${COLOR_YELLOW}[WARN]${COLOR_RESET} $1"
}

log_error() {
    echo -e "${COLOR_RED}[ERROR]${COLOR_RESET} $1"
}

check_dependencies() {
    local missing=()

    if ! command -v jq &> /dev/null; then
        missing+=("jq")
    fi

    if [ ${#missing[@]} -eq 0 ]; then
        return 0
    fi

    log_warning "Missing dependencies: ${missing[*]}"

    if command -v brew &> /dev/null; then
        log_info "Installing via Homebrew: ${missing[*]}"
        brew install "${missing[@]}"
        log_success "Dependencies installed: ${missing[*]}"
    elif command -v apt-get &> /dev/null; then
        log_info "Installing via apt: ${missing[*]}"
        sudo apt-get update -qq && sudo apt-get install -y -qq "${missing[@]}"
        log_success "Dependencies installed: ${missing[*]}"
    else
        log_error "Cannot auto-install dependencies. No supported package manager found (brew/apt)"
        log_info "Please install manually: ${missing[*]}"
        exit 1
    fi
}

ensure_claude_dir() {
    if [ ! -d "$CLAUDE_DIR" ]; then
        log_info "Creating $CLAUDE_DIR"
        mkdir -p "$CLAUDE_DIR"
    fi
}

backup_file() {
    local file=$1
    if [ -f "$file" ]; then
        local backup="${file}.backup.$(date +%Y%m%d%H%M%S)"
        cp "$file" "$backup"
        log_info "Backup created: $backup"
    fi
}

install_statusline() {
    local force=${1:-false}
    local target="$CLAUDE_DIR/statusline.sh"
    local source="$SCRIPTS_DIR/statusline.sh"

    if [ -f "$target" ] && [ "$force" != "true" ]; then
        log_warning "statusline.sh already exists. Use --force to overwrite"
        return 1
    fi

    if [ -f "$target" ]; then
        backup_file "$target"
    fi

    cp "$source" "$target"
    chmod +x "$target"

    cp "$SCRIPTS_DIR/usage_chrome.sh" "$CLAUDE_DIR/usage_chrome.sh"
    cp "$SCRIPTS_DIR/usage_native.sh" "$CLAUDE_DIR/usage_native.sh"
    log_success "Installed: $target (with usage modules)"
}

install_git_hooks() {
    local force=${1:-false}

    mkdir -p "$GIT_HOOKS_TARGET"

    for hook_file in "$GIT_HOOKS_DIR"/*; do
        [[ -f "$hook_file" ]] || continue
        local hook_name
        hook_name=$(basename "$hook_file")
        local target="$GIT_HOOKS_TARGET/$hook_name"

        if [ -f "$target" ] && [ "$force" != "true" ]; then
            log_warning "git-hooks/$hook_name already exists. Use --force to overwrite"
            continue
        fi

        if [ -f "$target" ]; then
            backup_file "$target"
        fi

        cp "$hook_file" "$target"
        chmod +x "$target"
        log_success "Installed: $target"
    done

    local current_hooks_path
    current_hooks_path=$(git config --global core.hooksPath 2>/dev/null || true)

    if [[ "$current_hooks_path" != "$GIT_HOOKS_TARGET" ]]; then
        if [[ -n "$current_hooks_path" ]]; then
            log_warning "Changing global core.hooksPath: $current_hooks_path → $GIT_HOOKS_TARGET"
        fi
        git config --global core.hooksPath "$GIT_HOOKS_TARGET"
        log_success "Set global core.hooksPath = $GIT_HOOKS_TARGET"
    else
        log_success "Global core.hooksPath already set to $GIT_HOOKS_TARGET"
    fi
}

install_hooks() {
    local force=${1:-false}
    local hooks_target_dir="$CLAUDE_DIR/hooks"

    mkdir -p "$hooks_target_dir"

    local target="$hooks_target_dir/save-model.sh"
    local source="$HOOKS_DIR/save-model.sh"

    if [ -f "$target" ] && [ "$force" != "true" ]; then
        log_warning "hooks/save-model.sh already exists. Use --force to overwrite"
        return 0
    fi

    if [ -f "$target" ]; then
        backup_file "$target"
    fi

    cp "$source" "$target"
    chmod +x "$target"
    log_success "Installed: $target"
}

configure_hooks_settings() {
    local settings_file="$CLAUDE_DIR/settings.json"
    local hook_command="~/.claude/hooks/save-model.sh"

    if [ ! -f "$settings_file" ]; then
        return 0
    fi

    local already_configured
    already_configured=$(jq --arg cmd "$hook_command" '
        [.hooks.SessionStart[]?.hooks[]? | select(.command == $cmd)] | length
    ' "$settings_file" 2>/dev/null || echo 0)

    if [ "$already_configured" != "0" ]; then
        log_warning "save-model hook already configured in settings.json"
        return 0
    fi

    backup_file "$settings_file"
    jq --arg cmd "$hook_command" '
        .hooks.SessionStart += [{"matcher": "", "hooks": [{"type": "command", "command": $cmd, "async": true}]}]
    ' "$settings_file" > "${settings_file}.tmp"
    mv "${settings_file}.tmp" "$settings_file"
    log_success "Configured hooks in settings.json"
}

configure_settings() {
    local settings_file="$CLAUDE_DIR/settings.json"
    local statusline_config='{"type":"command","command":"~/.claude/statusline.sh"}'

    if [ ! -f "$settings_file" ]; then
        log_info "Creating settings.json"
        echo "{\"statusLine\":$statusline_config}" | jq '.' > "$settings_file"
        log_success "Created: $settings_file"
        return 0
    fi

    if jq -e '.statusLine' "$settings_file" > /dev/null 2>&1; then
        log_warning "statusLine already configured in settings.json"
        return 0
    fi

    backup_file "$settings_file"
    jq --argjson sl "$statusline_config" '. + {statusLine: $sl}' "$settings_file" > "${settings_file}.tmp"
    mv "${settings_file}.tmp" "$settings_file"
    log_success "Updated: $settings_file"
}

setup_chrome() {
    if ! pgrep -x "Google Chrome" >/dev/null 2>&1; then
        log_info "Opening Chrome with claude.ai..."
        open -a "Google Chrome" "https://claude.ai" 2>/dev/null || true
        sleep 2
    else
        local has_claude_tab
        has_claude_tab=$(osascript -e '
            tell application "Google Chrome"
                repeat with w in windows
                    repeat with t in tabs of w
                        if URL of t contains "claude.ai" then return "yes"
                    end repeat
                end repeat
                return "no"
            end tell
        ' 2>/dev/null || echo "no")

        if [[ "$has_claude_tab" != "yes" ]]; then
            log_info "Opening claude.ai tab in Chrome..."
            osascript -e 'tell application "Google Chrome" to open location "https://claude.ai"' 2>/dev/null || true
            sleep 2
        else
            log_success "Chrome: claude.ai tab found"
        fi
    fi

    local js_test
    js_test=$(osascript -e '
        tell application "Google Chrome"
            repeat with w in windows
                repeat with t in tabs of w
                    if URL of t contains "claude.ai" then
                        return (execute t javascript "\"ok\"")
                    end if
                end repeat
            end repeat
        end tell
    ' 2>&1 || true)

    if echo "$js_test" | grep -q "Executing JavaScript through AppleScript is turned off"; then
        log_warning "Chrome JS from Apple Events is disabled"
        echo ""
        echo "  Enable it: Chrome → View → Developer → Allow JavaScript from Apple Events"
        echo ""
    elif [[ "$js_test" == "ok" ]]; then
        log_success "Chrome: JavaScript from Apple Events enabled"
    fi
}

do_install() {
    local force=${1:-false}

    log_info "Installing Claude Code tools..."
    echo

    check_dependencies
    ensure_claude_dir

    install_statusline "$force"
    install_hooks "$force"
    install_git_hooks "$force"
    configure_settings
    configure_hooks_settings
    setup_chrome

    echo
    log_success "Installation complete!"
    log_info "Restart Claude Code to apply changes"
}

do_uninstall() {
    log_info "Uninstalling Claude Code tools..."
    echo

    local statusline="$CLAUDE_DIR/statusline.sh"
    local settings="$CLAUDE_DIR/settings.json"

    if [ -f "$statusline" ]; then
        rm "$statusline"
        log_success "Removed: $statusline"
    else
        log_warning "Not found: $statusline"
    fi

    for module in usage_chrome.sh usage_native.sh; do
        local module_file="$CLAUDE_DIR/$module"
        if [ -f "$module_file" ]; then
            rm "$module_file"
            log_success "Removed: $module_file"
        fi
    done

    local hook="$CLAUDE_DIR/hooks/save-model.sh"
    if [ -f "$hook" ]; then
        rm "$hook"
        log_success "Removed: $hook"
    else
        log_warning "Not found: $hook"
    fi

    for hook_file in "$GIT_HOOKS_TARGET"/*; do
        [[ -f "$hook_file" ]] || continue
        rm "$hook_file"
        log_success "Removed: $hook_file"
    done
    if [ -d "$GIT_HOOKS_TARGET" ] && [ -z "$(ls -A "$GIT_HOOKS_TARGET" 2>/dev/null)" ]; then
        rmdir "$GIT_HOOKS_TARGET"
        log_success "Removed: $GIT_HOOKS_TARGET"
    fi
    local current_hooks_path
    current_hooks_path=$(git config --global core.hooksPath 2>/dev/null || true)
    if [[ "$current_hooks_path" == "$GIT_HOOKS_TARGET" ]]; then
        git config --global --unset core.hooksPath
        log_success "Unset global core.hooksPath"
    fi

    if [ -f "$settings" ] && jq -e '.statusLine' "$settings" > /dev/null 2>&1; then
        backup_file "$settings"
        jq 'del(.statusLine) | del(.hooks.SessionStart[] | select(.hooks[]?.command == "~/.claude/hooks/save-model.sh")) | del(.hooks.ConfigChange[] | select(.hooks[]?.command == "~/.claude/hooks/save-model.sh"))' "$settings" > "${settings}.tmp" 2>/dev/null || jq 'del(.statusLine)' "$settings" > "${settings}.tmp"
        mv "${settings}.tmp" "$settings"
        log_success "Removed statusLine and hooks from settings.json"
    fi

    echo
    log_success "Uninstall complete!"
}

do_status() {
    log_info "Checking installation status..."
    echo

    local statusline="$CLAUDE_DIR/statusline.sh"
    local settings="$CLAUDE_DIR/settings.json"

    if [ -f "$statusline" ]; then
        log_success "statusline.sh: installed"
    else
        log_warning "statusline.sh: not installed"
    fi

    local hook="$CLAUDE_DIR/hooks/save-model.sh"
    if [ -f "$hook" ]; then
        log_success "hooks/save-model.sh: installed"
    else
        log_warning "hooks/save-model.sh: not installed"
    fi

    local git_hooks_path
    git_hooks_path=$(git config --global core.hooksPath 2>/dev/null || true)
    if [[ "$git_hooks_path" == "$GIT_HOOKS_TARGET" ]]; then
        log_success "git-hooks: core.hooksPath = $GIT_HOOKS_TARGET"
        for hook_file in "$GIT_HOOKS_TARGET"/*; do
            [[ -f "$hook_file" ]] || continue
            log_success "  $(basename "$hook_file"): installed"
        done
    else
        log_warning "git-hooks: not configured (core.hooksPath = ${git_hooks_path:-<unset>})"
    fi

    if [ -f "$settings" ] && jq -e '.statusLine' "$settings" > /dev/null 2>&1; then
        log_success "settings.json: statusLine configured"
    else
        log_warning "settings.json: statusLine not configured"
    fi

    if [ -f "$settings" ] && jq -e '.hooks.SessionStart' "$settings" > /dev/null 2>&1; then
        log_success "settings.json: hooks configured"
    else
        log_warning "settings.json: hooks not configured"
    fi

    if pgrep -x "Google Chrome" >/dev/null 2>&1; then
        local has_tab
        has_tab=$(osascript -e '
            tell application "Google Chrome"
                repeat with w in windows
                    repeat with t in tabs of w
                        if URL of t contains "claude.ai" then return "yes"
                    end repeat
                end repeat
                return "no"
            end tell
        ' 2>/dev/null || echo "no")
        if [[ "$has_tab" == "yes" ]]; then
            log_success "Chrome: claude.ai tab open"
        else
            log_warning "Chrome: no claude.ai tab (open claude.ai in Chrome)"
        fi
    else
        log_warning "Chrome: not running"
    fi
}

main() {
    local command="install"
    local force=false

    while [[ $# -gt 0 ]]; do
        case $1 in
            -h|--help)
                show_help
                exit 0
                ;;
            -v|--version)
                show_version
                exit 0
                ;;
            -f|--force)
                force=true
                shift
                ;;
            install|uninstall|status)
                command=$1
                shift
                ;;
            *)
                log_error "Unknown option: $1"
                show_help
                exit 1
                ;;
        esac
    done

    case $command in
        install)
            do_install "$force"
            ;;
        uninstall)
            do_uninstall
            ;;
        status)
            do_status
            ;;
    esac
}

main "$@"
