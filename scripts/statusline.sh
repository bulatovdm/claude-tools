#!/bin/bash

set -euo pipefail

readonly SCRIPT_NAME=$(basename "$0")
readonly VERSION="2.0.0"

readonly COLOR_GREEN="\033[32m"
readonly COLOR_YELLOW="\033[33m"
readonly COLOR_RED="\033[31m"
readonly COLOR_GRAY="\033[90m"
readonly COLOR_RESET="\033[0m"

readonly AUTOCOMPACT_TRIGGER_USED=77

readonly BAR_WIDTH=15
readonly BAR_FILLED="█"
readonly BAR_EMPTY="░"

show_help() {
    cat << EOF
Usage: $SCRIPT_NAME [OPTIONS]

Claude Code status line with visual progress bar.
Shows context usage and autocompact trigger (at ${AUTOCOMPACT_TRIGGER_USED}% usage).

Options:
    -h, --help      Show this help message
    -v, --version   Show version
    -t, --test      Run with test data

Examples:
    echo '{"context_window":{"used_percentage":70}}' | $SCRIPT_NAME
    $SCRIPT_NAME --test

EOF
}

show_version() {
    echo "$SCRIPT_NAME version $VERSION"
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
    local until_ac

    until_ac=$((AUTOCOMPACT_TRIGGER_USED - used))

    if (( until_ac < 0 )); then
        until_ac=0
    fi

    echo "$until_ac"
}

format_output() {
    local used=$1
    local until_ac=$2

    local used_color
    local ac_color
    local used_bar
    local ac_bar
    local show_ac_threshold=10

    used_color=$(get_color_by_percentage "$used" "false")
    used_bar=$(build_progress_bar "$used" "$used_color")

    if (( until_ac <= show_ac_threshold )); then
        ac_color=$(get_color_by_percentage "$until_ac" "true")
        ac_bar=$(build_progress_bar "$until_ac" "$ac_color")
        echo -e "${COLOR_GRAY}Context:${COLOR_RESET} ${used_bar} ${used_color}${used}%${COLOR_RESET} ${COLOR_GRAY}│ Left until auto-compact:${COLOR_RESET} ${ac_bar} ${ac_color}${until_ac}%${COLOR_RESET}"
    else
        echo -e "${COLOR_GRAY}Context:${COLOR_RESET} ${used_bar} ${used_color}${used}%${COLOR_RESET}"
    fi
}

run_test() {
    echo "Trigger at: ${AUTOCOMPACT_TRIGGER_USED}%"
    echo ""
    echo "Normal (AC hidden, until_ac > 10%):"
    format_output "45" "32"
    echo ""
    echo "Warning (AC visible, until_ac <= 10%):"
    format_output "70" "7"
    echo ""
    echo "Critical (AC visible, until_ac = 0%):"
    format_output "77" "0"
}

main() {
    local input
    local used
    local until_ac

    input=$(cat)
    used=$(parse_used_percentage "$input")
    until_ac=$(calculate_until_autocompact "$used")

    format_output "$used" "$until_ac"
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
