#!/bin/bash

set -euo pipefail

readonly SCRIPT_NAME=$(basename "$0")
readonly VERSION="3.2.0"

readonly COLOR_GREEN="\033[32m"
readonly COLOR_YELLOW="\033[33m"
readonly COLOR_RED="\033[31m"
readonly COLOR_GRAY="\033[90m"
readonly COLOR_CYAN="\033[36m"
readonly COLOR_RESET="\033[0m"

readonly BAR_WIDTH=15
readonly BAR_FILLED="█"
readonly BAR_EMPTY="░"

readonly USAGE_CACHE_FILE="/tmp/claude-statusline-usage-cache"
readonly USAGE_CACHE_MAX_AGE=60

show_help() {
    cat << EOF
Usage: $SCRIPT_NAME [OPTIONS]

Claude Code status line with context bar, model, usage limits, cost, and session time.
Shows context usage, current model, 5-hour and weekly limits, session cost and duration.

Options:
    -h, --help      Show this help message
    -v, --version   Show version
    -t, --test      Run with test data

Examples:
    echo '{"context_window":{"used_percentage":70},"model":{"display_name":"Opus"}}' | $SCRIPT_NAME
    $SCRIPT_NAME --test

EOF
}

show_version() {
    echo "$SCRIPT_NAME version $VERSION"
}

get_color_by_percentage() {
    local percentage=$1

    if (( percentage < 60 )); then
        echo "$COLOR_GREEN"
    elif (( percentage < 80 )); then
        echo "$COLOR_YELLOW"
    else
        echo "$COLOR_RED"
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

parse_model_name() {
    local input=$1
    echo "$input" | jq -r '.model.display_name // "?"'
}

parse_cost() {
    local input=$1
    echo "$input" | jq -r '.cost.total_cost_usd // 0'
}

parse_duration() {
    local input=$1
    echo "$input" | jq -r '.cost.total_duration_ms // 0' | cut -d'.' -f1
}

format_duration() {
    local ms=$1
    local total_sec=$((ms / 1000))
    local hours=$((total_sec / 3600))
    local mins=$(((total_sec % 3600) / 60))

    if (( hours > 0 )); then
        echo "${hours}h ${mins}m"
    else
        echo "${mins}m"
    fi
}

format_cost() {
    local cost=$1
    printf '$%.2f' "$cost"
}

usage_cache_is_stale() {
    [[ ! -f "$USAGE_CACHE_FILE" ]] || \
    (( $(date +%s) - $(stat -f %m "$USAGE_CACHE_FILE" 2>/dev/null || echo 0) > USAGE_CACHE_MAX_AGE ))
}

fetch_usage_limits() {
    local credentials
    local token
    local response

    credentials=$(security find-generic-password -s "Claude Code-credentials" -w 2>/dev/null) || return 1
    token=$(echo "$credentials" | jq -r '.claudeAiOauth.accessToken // empty') || return 1

    [[ -z "$token" ]] && return 1

    response=$(curl -s --max-time 5 \
        "https://api.anthropic.com/api/oauth/usage" \
        -H "Authorization: Bearer $token" \
        -H "anthropic-beta: oauth-2025-04-20" 2>/dev/null) || return 1

    echo "$response" | jq -e '.five_hour' >/dev/null 2>&1 || return 1

    echo "$response" > "$USAGE_CACHE_FILE"
}

get_usage_limits() {
    if usage_cache_is_stale; then
        fetch_usage_limits || true
    fi

    if [[ -f "$USAGE_CACHE_FILE" ]]; then
        local five_hour seven_day sonnet
        five_hour=$(jq -r '.five_hour.utilization // empty' "$USAGE_CACHE_FILE" 2>/dev/null | cut -d'.' -f1)
        seven_day=$(jq -r '.seven_day.utilization // empty' "$USAGE_CACHE_FILE" 2>/dev/null | cut -d'.' -f1)
        sonnet=$(jq -r '.seven_day_sonnet.utilization // empty' "$USAGE_CACHE_FILE" 2>/dev/null | cut -d'.' -f1)
        echo "${five_hour:-}|${seven_day:-}|${sonnet:-}"
    else
        echo "||"
    fi
}

format_usage_part() {
    local label=$1
    local value=$2

    if [[ -z "$value" ]]; then
        echo -e "${COLOR_GRAY}${label}: ?${COLOR_RESET}"
        return
    fi

    local color
    color=$(get_color_by_percentage "$value")
    echo -e "${COLOR_GRAY}${label}:${COLOR_RESET} ${color}${value}%${COLOR_RESET}"
}

format_output() {
    local used=$1
    local model=$2
    local five_hour=$3
    local seven_day=$4
    local sonnet=$5
    local cost=$6
    local duration_ms=$7

    local used_color
    local used_bar
    used_color=$(get_color_by_percentage "$used")
    used_bar=$(build_progress_bar "$used" "$used_color")

    local context_part="${COLOR_GRAY}Context:${COLOR_RESET} ${used_bar} ${used_color}${used}%${COLOR_RESET}"
    local model_part="${COLOR_CYAN}${model}${COLOR_RESET}"
    local five_hour_part
    local seven_day_part
    local sonnet_part
    five_hour_part=$(format_usage_part "5h" "$five_hour")
    seven_day_part=$(format_usage_part "Week" "$seven_day")
    sonnet_part=$(format_usage_part "Sonnet" "$sonnet")

    local cost_part="${COLOR_GRAY}Cost:${COLOR_RESET} ${COLOR_YELLOW}$(format_cost "$cost")${COLOR_RESET}"
    local duration_part="${COLOR_GRAY}Time:${COLOR_RESET} $(format_duration "$duration_ms")"

    echo -e "${model_part} ${COLOR_GRAY}│${COLOR_RESET} ${context_part} ${COLOR_GRAY}│${COLOR_RESET} ${five_hour_part} ${COLOR_GRAY}│${COLOR_RESET} ${seven_day_part} ${COLOR_GRAY}│${COLOR_RESET} ${sonnet_part} ${COLOR_GRAY}│${COLOR_RESET} ${cost_part} ${COLOR_GRAY}│${COLOR_RESET} ${duration_part}"
}

run_test() {
    echo "Test output at different usage levels:"
    echo ""
    echo "Low usage (45%), short session:"
    format_output "45" "Opus" "6" "35" "3" "0.42" "300000"
    echo ""
    echo "Medium usage (70%), longer session:"
    format_output "70" "Sonnet" "50" "60" "20" "2.15" "1800000"
    echo ""
    echo "High usage (85%), expensive session:"
    format_output "85" "Opus" "80" "90" "65" "8.73" "7200000"
    echo ""
    echo "No limits data:"
    format_output "45" "Opus" "" "" "" "0.01" "60000"
}

main() {
    local input
    local used
    local model
    local cost
    local duration_ms
    local usage_data
    local five_hour
    local seven_day
    local sonnet
    local remaining

    input=$(cat)
    used=$(parse_used_percentage "$input")
    model=$(parse_model_name "$input")
    cost=$(parse_cost "$input")
    duration_ms=$(parse_duration "$input")

    usage_data=$(get_usage_limits)
    five_hour="${usage_data%%|*}"
    remaining="${usage_data#*|}"
    seven_day="${remaining%%|*}"
    sonnet="${remaining#*|}"

    format_output "$used" "$model" "$five_hour" "$seven_day" "$sonnet" "$cost" "$duration_ms"
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
