#!/bin/bash

set -euo pipefail

readonly SCRIPT_NAME=$(basename "$0")
readonly VERSION="1.0.0"
readonly CLAUDE_DIR="$HOME/.claude"
readonly SCRIPTS_DIR="$(cd "$(dirname "$0")" && pwd)/scripts"

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
    log_success "Installed: $target"
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

do_install() {
    local force=${1:-false}

    log_info "Installing Claude Code tools..."
    echo

    check_dependencies
    ensure_claude_dir

    install_statusline "$force"
    configure_settings

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

    if [ -f "$settings" ] && jq -e '.statusLine' "$settings" > /dev/null 2>&1; then
        backup_file "$settings"
        jq 'del(.statusLine)' "$settings" > "${settings}.tmp"
        mv "${settings}.tmp" "$settings"
        log_success "Removed statusLine from settings.json"
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

    if [ -f "$settings" ] && jq -e '.statusLine' "$settings" > /dev/null 2>&1; then
        log_success "settings.json: configured"
    else
        log_warning "settings.json: not configured"
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
