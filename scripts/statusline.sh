#!/bin/bash

set -euo pipefail

readonly SCRIPT_NAME=$(basename "$0")
readonly VERSION="2.0.0"

readonly COLOR_GREEN="\033[32m"
readonly COLOR_YELLOW="\033[33m"
readonly COLOR_RED="\033[31m"
readonly COLOR_GRAY="\033[90m"
readonly COLOR_RESET="\033[0m"

readonly SETTINGS_FILE="$HOME/.claude/settings.json"
readonly DEFAULT_AUTOCOMPACT_PCT=95
readonly AUTOCOMPACT_BUFFER_PCT=22

readonly BAR_WIDTH=10
readonly BAR_FILLED="█"
readonly BAR_EMPTY="░"

show_help() {
    cat << EOF
Usage: $SCRIPT_NAME [OPTIONS]

Claude Code status line with visual progress bar.
Shows context usage and autocompact trigger threshold.

Options:
    -h, --help      Show this help message
    -v, --version   Show version
    -t, --test      Run with test data

Configuration:
    ~/.claude/settings.json -> env.CLAUDE_AUTOCOMPACT_PCT_OVERRIDE

Examples:
    echo '{"context_window":{"used_percentage":70}}' | $SCRIPT_NAME
    $SCRIPT_NAME --test

EOF
}

show_version() {
    echo "$SCRIPT_NAME version $VERSION"
}

get_autocompact_threshold() {
    local threshold=""

    if [ -f "$SETTINGS_FILE" ]; then
        threshold=$(jq -r '.env.CLAUDE_AUTOCOMPACT_PCT_OVERRIDE // empty' "$SETTINGS_FILE" 2>/dev/null || true)
    fi

    if [ -z "$threshold" ]; then
        threshold="${CLAUDE_AUTOCOMPACT_PCT_OVERRIDE:-$DEFAULT_AUTOCOMPACT_PCT}"
    fi

    echo "$threshold"
}

is_autocompact_enabled() {
    local threshold
    threshold=$(get_autocompact_threshold)

    if [ "$threshold" -gt 0 ] 2>/dev/null; then
        echo "true"
    else
        echo "false"
    fi
}

get_color_by_percentage() {
    local percentage=$1
    local invert=${2:-false}

    if [ "$invert" = "true" ]; then
        if (( percentage > 40 )); then
            echo "$COLOR_GREEN"
        elif (( percentage > 20 )); then
            echo "$COLOR_YELLOW"
        else
            echo "$COLOR_RED"
        fi
    else
        if (( percentage < 60 )); then
            echo "$COLOR_GREEN"
        elif (( percentage < 80 )); then
            echo "$COLOR_YELLOW"
        else
            echo "$COLOR_RED"
        fi
    fi
}

build_progress_bar() {
    local percentage=$1
    local color=$2
    local filled_count
    local empty_count
    local bar=""

    filled_count=$((percentage * BAR_WIDTH / 100))
    empty_count=$((BAR_WIDTH - filled_count))

    if (( filled_count > BAR_WIDTH )); then
        filled_count=$BAR_WIDTH
        empty_count=0
    fi

    if (( filled_count < 0 )); then
        filled_count=0
        empty_count=$BAR_WIDTH
    fi

    for ((i=0; i<filled_count; i++)); do
        bar+="$BAR_FILLED"
    done

    for ((i=0; i<empty_count; i++)); do
        bar+="$BAR_EMPTY"
    done

    echo -e "${color}${bar}${COLOR_RESET}"
}

parse_used_percentage() {
    local input=$1
    echo "$input" | jq -r '.context_window.used_percentage // 0' | cut -d'.' -f1
}

calculate_until_autocompact() {
    local used=$1
    local threshold
    local until_ac

    threshold=$(get_autocompact_threshold)
    until_ac=$((threshold - AUTOCOMPACT_BUFFER_PCT - used))

    if (( until_ac < 0 )); then
        until_ac=0
    fi

    echo "$until_ac"
}

format_output() {
    local used=$1
    local until_ac=$2
    local ac_enabled=$3

    local used_color
    local ac_color
    local used_bar
    local ac_bar
    local show_ac_threshold=10

    used_color=$(get_color_by_percentage "$used" "false")
    used_bar=$(build_progress_bar "$used" "$used_color")

    if [ "$ac_enabled" = "true" ] && (( until_ac <= show_ac_threshold )); then
        ac_color=$(get_color_by_percentage "$until_ac" "true")
        ac_bar=$(build_progress_bar "$until_ac" "$ac_color")
        echo -e "Context: ${used_bar} ${used_color}${used}%${COLOR_RESET} ${COLOR_GRAY}│${COLOR_RESET} AC: ${ac_bar} ${ac_color}${until_ac}%${COLOR_RESET}"
    else
        echo -e "Context: ${used_bar} ${used_color}${used}%${COLOR_RESET}"
    fi
}

run_test() {
    local ac_enabled
    ac_enabled=$(is_autocompact_enabled)

    echo "AC enabled: ${ac_enabled}"
    echo ""
    echo "Normal (AC hidden, until_ac > 10%):"
    format_output "45" "28" "$ac_enabled"
    echo ""
    echo "Warning (AC visible, until_ac <= 10%):"
    format_output "63" "10" "$ac_enabled"
    echo ""
    echo "Critical (AC visible, until_ac = 0%):"
    format_output "73" "0" "$ac_enabled"
}

main() {
    local input
    local used
    local until_ac
    local ac_enabled

    input=$(cat)
    used=$(parse_used_percentage "$input")
    ac_enabled=$(is_autocompact_enabled)
    until_ac=$(calculate_until_autocompact "$used")

    format_output "$used" "$until_ac" "$ac_enabled"
}

case "${1:-}" in
    -h|--help)
        show_help
        exit 0
        ;;
    -v|--version)
        show_version
        exit 0
        ;;
    -t|--test)
        run_test
        exit 0
        ;;
    *)
        main
        ;;
esac
