#!/bin/bash

set -euo pipefail

readonly SCRIPT_NAME=$(basename "$0")
readonly VERSION="3.3.1"

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
readonly USAGE_CACHE_RETRY_FILE="/tmp/claude-statusline-usage-retry"
readonly USAGE_CACHE_REFRESH_FAILED_FILE="/tmp/claude-statusline-refresh-failed"
readonly USAGE_CACHE_LOCK_FILE="/tmp/claude-statusline-usage-lock"
readonly USAGE_CACHE_MAX_AGE=300
readonly USAGE_CACHE_STALE_AGE=900
readonly USAGE_CACHE_LOCK_TIMEOUT=10
readonly OAUTH_REFRESH_MAX_ATTEMPTS=2
readonly OAUTH_CLIENT_ID="9d1c250a-e61b-44d9-88ed-5944d1962f5e"

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
    local session_id
    session_id=$(echo "$input" | jq -r '.session_id // empty')

    if [[ -n "$session_id" && -f "/tmp/claude-model-${session_id}" ]]; then
        cat "/tmp/claude-model-${session_id}"
        return
    fi

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

seconds_until_reset() {
    local reset_iso=$1

    [[ -z "$reset_iso" || "$reset_iso" == "null" ]] && return 1

    local reset_epoch
    reset_epoch=$(TZ=UTC date -jf "%Y-%m-%dT%H:%M:%S" "${reset_iso%%.*}" +%s 2>/dev/null) || return 1
    local now_epoch
    now_epoch=$(date -u +%s)
    echo $(( reset_epoch - now_epoch ))
}

format_time_remaining() {
    local diff=$1

    (( diff <= 0 )) && { echo "now"; return; }

    local days=$(( diff / 86400 ))
    local hours=$(( (diff % 86400) / 3600 ))
    local mins=$(( (diff % 3600) / 60 ))

    if (( days > 0 )); then
        echo "${days}d${hours}h"
    elif (( hours > 0 )); then
        echo "${hours}h${mins}m"
    else
        echo "${mins}m"
    fi
}

timer_icon_for_seconds() {
    local seconds=$1
    local window_seconds=$2

    (( seconds <= 0 )) && { echo "○"; return; }

    local pct=$(( seconds * 100 / window_seconds ))

    if (( pct > 87 )); then
        echo "●"
    elif (( pct > 62 )); then
        echo "◕"
    elif (( pct > 37 )); then
        echo "◑"
    elif (( pct > 12 )); then
        echo "◔"
    else
        echo "○"
    fi
}

usage_cache_is_stale() {
    local now
    now=$(date +%s)
    local cache_age=$(( now - $(stat -f %m "$USAGE_CACHE_FILE" 2>/dev/null || echo 0) ))
    local retry_age=$(( now - $(stat -f %m "$USAGE_CACHE_RETRY_FILE" 2>/dev/null || echo 0) ))
    local failed_age=$(( now - $(stat -f %m "$USAGE_CACHE_REFRESH_FAILED_FILE" 2>/dev/null || echo 0) ))

    [[ ! -f "$USAGE_CACHE_FILE" ]] && [[ ! -f "$USAGE_CACHE_RETRY_FILE" ]] && [[ ! -f "$USAGE_CACHE_REFRESH_FAILED_FILE" ]] && return 0
    (( cache_age <= USAGE_CACHE_MAX_AGE )) && return 1
    (( retry_age <= USAGE_CACHE_MAX_AGE )) && return 1
    (( failed_age <= USAGE_CACHE_MAX_AGE )) && return 1
    return 0
}

credentials_are_hex_encoded() {
    local raw=$1
    echo "$raw" | jq -e '.' >/dev/null 2>&1 && return 1
    return 0
}

read_credentials() {
    local raw
    raw=$(security find-generic-password -s "Claude Code-credentials" -w 2>/dev/null) || return 1
    if credentials_are_hex_encoded "$raw"; then
        echo "$raw" | xxd -r -p 2>/dev/null
    else
        echo "$raw"
    fi
}

write_credentials() {
    local json=$1
    local raw
    raw=$(security find-generic-password -s "Claude Code-credentials" -w 2>/dev/null) || return 1

    local encoded
    if credentials_are_hex_encoded "$raw"; then
        encoded=$(printf '%s' "$json" | xxd -p | tr -d '\n')
    else
        encoded=$json
    fi

    security add-generic-password -s "Claude Code-credentials" -a "Claude Code-credentials" \
        -w "$encoded" -U 2>/dev/null || return 1
}

refresh_oauth_token() {
    local credentials
    local refresh_token
    local response
    local new_access_token
    local new_refresh_token

    credentials=$(read_credentials) || return 1
    refresh_token=$(echo "$credentials" | jq -r '.claudeAiOauth.refreshToken // empty') || return 1
    [[ -z "$refresh_token" ]] && return 1

    response=$(curl -s --max-time 10 \
        "https://console.anthropic.com/v1/oauth/token" \
        -H "Content-Type: application/json" \
        -d "{\"grant_type\":\"refresh_token\",\"refresh_token\":\"${refresh_token}\",\"client_id\":\"${OAUTH_CLIENT_ID}\"}" \
        2>/dev/null) || return 1

    new_access_token=$(echo "$response" | jq -r '.access_token // empty')
    new_refresh_token=$(echo "$response" | jq -r '.refresh_token // empty')

    [[ -z "$new_access_token" || -z "$new_refresh_token" ]] && return 1

    local updated_credentials
    updated_credentials=$(echo "$credentials" | jq \
        --arg at "$new_access_token" \
        --arg rt "$new_refresh_token" \
        '.claudeAiOauth.accessToken = $at | .claudeAiOauth.refreshToken = $rt') || return 1

    write_credentials "$updated_credentials" || return 1
}

request_usage_with_token() {
    local token=$1
    local response

    response=$(curl -s --max-time 5 \
        "https://api.anthropic.com/api/oauth/usage" \
        -H "Authorization: Bearer $token" \
        -H "anthropic-beta: oauth-2025-04-20" 2>/dev/null) || return 1

    echo "$response" | jq -e '.five_hour' >/dev/null 2>&1 || return 1

    echo "$response" > "$USAGE_CACHE_FILE"
}

fetch_usage_limits() {
    local credentials
    local token

    credentials=$(read_credentials) || return 1
    token=$(echo "$credentials" | jq -r '.claudeAiOauth.accessToken // empty') || return 1
    [[ -z "$token" ]] && return 1

    request_usage_with_token "$token" && { rm -f "$USAGE_CACHE_REFRESH_FAILED_FILE"; return 0; }

    local attempt=0
    while (( attempt < OAUTH_REFRESH_MAX_ATTEMPTS )); do
        attempt=$(( attempt + 1 ))
        refresh_oauth_token || break

        credentials=$(read_credentials) || break
        token=$(echo "$credentials" | jq -r '.claudeAiOauth.accessToken // empty') || break
        [[ -z "$token" ]] && break

        request_usage_with_token "$token" && { rm -f "$USAGE_CACHE_REFRESH_FAILED_FILE"; return 0; }
    done

    touch "$USAGE_CACHE_REFRESH_FAILED_FILE" 2>/dev/null || true
    return 1
}

usage_cache_is_valid() {
    [[ -f "$USAGE_CACHE_FILE" ]] && \
    (( $(date +%s) - $(stat -f %m "$USAGE_CACHE_FILE" 2>/dev/null || echo 0) < USAGE_CACHE_STALE_AGE )) && \
    jq -e '.five_hour' "$USAGE_CACHE_FILE" >/dev/null 2>&1
}

fetch_usage_limits_if_still_stale() {
    usage_cache_is_stale || return 0
    fetch_usage_limits || touch "$USAGE_CACHE_RETRY_FILE" 2>/dev/null || true
}

with_fetch_lock() {
    local deadline=$(( $(date +%s) + USAGE_CACHE_LOCK_TIMEOUT ))
    until mkdir "$USAGE_CACHE_LOCK_FILE" 2>/dev/null; do
        (( $(date +%s) >= deadline )) && { "$@"; return; }
        sleep 0.2
    done
    "$@"
    rmdir "$USAGE_CACHE_LOCK_FILE" 2>/dev/null || true
}

get_usage_limits() {
    if usage_cache_is_stale; then
        with_fetch_lock fetch_usage_limits_if_still_stale
    fi

    if [[ -f "$USAGE_CACHE_REFRESH_FAILED_FILE" ]]; then
        echo "refresh_failed|||||"
        return
    fi

    if usage_cache_is_valid; then
        local five_hour seven_day sonnet five_hour_reset seven_day_reset sonnet_reset
        five_hour=$(jq -r '.five_hour.utilization // empty' "$USAGE_CACHE_FILE" 2>/dev/null | cut -d'.' -f1)
        seven_day=$(jq -r '.seven_day.utilization // empty' "$USAGE_CACHE_FILE" 2>/dev/null | cut -d'.' -f1)
        sonnet=$(jq -r '.seven_day_sonnet.utilization // empty' "$USAGE_CACHE_FILE" 2>/dev/null | cut -d'.' -f1)
        five_hour_reset=$(jq -r '.five_hour.resets_at // empty' "$USAGE_CACHE_FILE" 2>/dev/null)
        seven_day_reset=$(jq -r '.seven_day.resets_at // empty' "$USAGE_CACHE_FILE" 2>/dev/null)
        sonnet_reset=$(jq -r '.seven_day_sonnet.resets_at // empty' "$USAGE_CACHE_FILE" 2>/dev/null)
        echo "${five_hour:-}|${seven_day:-}|${sonnet:-}|${five_hour_reset:-}|${seven_day_reset:-}|${sonnet_reset:-}"
    else
        echo "|||||"
    fi
}

format_usage_part() {
    local label=$1
    local value=$2
    local reset_iso=${3:-}
    local window_seconds=${4:-18000}

    if [[ -z "$value" ]]; then
        echo -e "${COLOR_GRAY}${label}: ?${COLOR_RESET}"
        return
    fi

    local color
    color=$(get_color_by_percentage "$value")

    local reset_str=""
    if [[ -n "$reset_iso" ]]; then
        local seconds_left
        seconds_left=$(seconds_until_reset "$reset_iso") || seconds_left=0
        local icon
        icon=$(timer_icon_for_seconds "$seconds_left" "$window_seconds")
        local time_str
        time_str=$(format_time_remaining "$seconds_left")
        reset_str=" ${COLOR_GRAY}${time_str} ${icon}${COLOR_RESET}"
    fi

    echo -e "${COLOR_GRAY}${label}:${COLOR_RESET} ${color}${value}%${COLOR_RESET}${reset_str}"
}

format_output() {
    local used=$1
    local model=$2
    local five_hour=$3
    local seven_day=$4
    local sonnet=$5
    local five_hour_reset=$6
    local seven_day_reset=$7
    local sonnet_reset=$8
    local cost=$9
    local duration_ms=${10}
    local refresh_failed=${11:-}

    local used_color
    local used_bar
    used_color=$(get_color_by_percentage "$used")
    used_bar=$(build_progress_bar "$used" "$used_color")

    local context_part="${COLOR_GRAY}Context:${COLOR_RESET} ${used_bar} ${used_color}${used}%${COLOR_RESET}"
    local model_part="${COLOR_CYAN}${model}${COLOR_RESET}"
    local five_hour_part
    local seven_day_part
    local sonnet_part
    five_hour_part=$(format_usage_part "5h" "$five_hour" "$five_hour_reset" "18000")
    seven_day_part=$(format_usage_part "Week" "$seven_day" "$seven_day_reset" "604800")
    sonnet_part=$(format_usage_part "Sonnet" "$sonnet" "$sonnet_reset" "604800")

    local cost_part="${COLOR_GRAY}Cost:${COLOR_RESET} ${COLOR_YELLOW}$(format_cost "$cost")${COLOR_RESET}"
    local duration_part="${COLOR_GRAY}Time:${COLOR_RESET} $(format_duration "$duration_ms")"

    local refresh_failed_part=""
    if [[ "$refresh_failed" == "true" ]]; then
        refresh_failed_part=" ${COLOR_GRAY}│${COLOR_RESET} ${COLOR_GRAY}⚠ refresh failed${COLOR_RESET}"
    fi

    echo -e "${model_part} ${COLOR_GRAY}│${COLOR_RESET} ${context_part} ${COLOR_GRAY}│${COLOR_RESET} ${five_hour_part} ${COLOR_GRAY}│${COLOR_RESET} ${seven_day_part} ${COLOR_GRAY}│${COLOR_RESET} ${sonnet_part} ${COLOR_GRAY}│${COLOR_RESET} ${cost_part} ${COLOR_GRAY}│${COLOR_RESET} ${duration_part}${refresh_failed_part}"
}

run_test() {
    echo "Test output at different usage levels:"
    echo ""
    # Generate test reset times relative to now
    local now_epoch
    now_epoch=$(date +%s)
    local reset_2h reset_6d reset_5d
    reset_2h=$(date -r $((now_epoch + 7200)) +"%Y-%m-%dT%H:%M:%S" 2>/dev/null || echo "")
    reset_6d=$(date -r $((now_epoch + 518400)) +"%Y-%m-%dT%H:%M:%S" 2>/dev/null || echo "")
    reset_5d=$(date -r $((now_epoch + 432000)) +"%Y-%m-%dT%H:%M:%S" 2>/dev/null || echo "")

    echo "Low usage (45%), short session:"
    format_output "45" "Opus" "6" "35" "3" "$reset_2h" "$reset_6d" "$reset_5d" "0.42" "300000"
    echo ""
    echo "Medium usage (70%), longer session:"
    format_output "70" "Sonnet" "50" "60" "20" "$reset_2h" "$reset_6d" "$reset_5d" "2.15" "1800000"
    echo ""
    echo "High usage (85%), expensive session:"
    format_output "85" "Opus" "80" "90" "65" "$reset_2h" "$reset_6d" "$reset_5d" "8.73" "7200000"
    echo ""
    echo "No limits data:"
    format_output "45" "Opus" "" "" "" "" "" "" "0.01" "60000"
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
    local five_hour_reset
    local seven_day_reset
    local sonnet_reset
    local rest

    input=$(cat)
    used=$(parse_used_percentage "$input")
    model=$(parse_model_name "$input")
    cost=$(parse_cost "$input")
    duration_ms=$(parse_duration "$input")

    usage_data=$(get_usage_limits)
    local refresh_failed="false"
    if [[ "${usage_data%%|*}" == "refresh_failed" ]]; then
        refresh_failed="true"
        usage_data="|||||"
    fi
    five_hour="${usage_data%%|*}"
    rest="${usage_data#*|}"
    seven_day="${rest%%|*}"
    rest="${rest#*|}"
    sonnet="${rest%%|*}"
    rest="${rest#*|}"
    five_hour_reset="${rest%%|*}"
    rest="${rest#*|}"
    seven_day_reset="${rest%%|*}"
    sonnet_reset="${rest#*|}"

    format_output "$used" "$model" "$five_hour" "$seven_day" "$sonnet" "$five_hour_reset" "$seven_day_reset" "$sonnet_reset" "$cost" "$duration_ms" "$refresh_failed"
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
