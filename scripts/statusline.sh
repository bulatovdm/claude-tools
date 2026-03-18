#!/bin/bash

set -euo pipefail

readonly SCRIPT_NAME=$(basename "$0")
readonly VERSION="5.0.0"

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
readonly USAGE_CACHE_LOCK_FILE="/tmp/claude-statusline-usage-lock"
readonly USAGE_ERROR_FILE="/tmp/claude-statusline-error"
readonly USAGE_LOG_FILE="/tmp/claude-statusline.log"
readonly USAGE_CACHE_MAX_AGE=300
readonly USAGE_CACHE_STALE_AGE=600
readonly USAGE_CACHE_LOCK_TIMEOUT=10
readonly USAGE_CACHE_LOCK_STALE_AGE=60

show_help() {
    cat << EOF
Usage: $SCRIPT_NAME [OPTIONS]

Claude Code status line with context bar, model, usage limits, cost, and session time.
Shows context usage, current model, 5-hour and weekly limits, session cost and duration.
Fetches usage data from claude.ai via Chrome AppleScript.

Requires: Google Chrome with claude.ai tab open, "Allow JavaScript from Apple Events" enabled.

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

readonly MODEL_WINDOW_MAP="
claude-opus-4-6:1000000
claude-sonnet-4-6:200000
claude-haiku-4-5:200000
claude-opus-4-5:200000
claude-sonnet-4-5:200000
"

resolve_window_size_from_model_id() {
    local model_id=$1

    # Priority 1: custom map
    local entry
    while IFS= read -r entry; do
        [[ -z "$entry" ]] && continue
        local key="${entry%%:*}"
        local val="${entry##*:}"
        if [[ "$model_id" == "$key" ]]; then
            echo "$val"
            return
        fi
    done <<< "$MODEL_WINDOW_MAP"

    # Priority 2: suffix in brackets — [1m], [200k], [128k], etc.
    local suffix
    suffix=$(echo "$model_id" | grep -oE '\[([0-9]+)(m|k)\]' | tr -d '[]')
    if [[ -n "$suffix" ]]; then
        local num unit
        num=$(echo "$suffix" | grep -oE '^[0-9]+')
        unit=$(echo "$suffix" | grep -oE '[mk]$')
        if [[ "$unit" == "m" ]]; then
            echo $(( num * 1000000 ))
            return
        elif [[ "$unit" == "k" ]]; then
            echo $(( num * 1000 ))
            return
        fi
    fi

    # Fallback
    echo "200000"
}

parse_used_percentage() {
    local input=$1
    local session_id
    session_id=$(echo "$input" | jq -r '.session_id // empty')

    if [[ -n "$session_id" ]]; then
        local model_id_file="/tmp/claude-model-id-${session_id}"
        local ctx_file="/tmp/claude-ctx-${session_id}"

        if [[ ! -f "$ctx_file" ]]; then
            local window_size
            if [[ -f "$model_id_file" ]]; then
                window_size=$(resolve_window_size_from_model_id "$(cat "$model_id_file")")
            else
                local model_id
                model_id=$(echo "$input" | jq -r '.model.id // empty')
                window_size=$(resolve_window_size_from_model_id "$model_id")
                [[ -n "$model_id" ]] && echo "$model_id" > "$model_id_file"
            fi
            echo "$window_size" > "$ctx_file"
        fi

        # Auto-upgrade: if stdin reports a larger window, session switched to a bigger model
        local stdin_window_size
        stdin_window_size=$(echo "$input" | jq -r '.context_window.context_window_size // 0')
        local frozen_size
        frozen_size=$(cat "$ctx_file")
        if [[ "$stdin_window_size" -gt "$frozen_size" ]]; then
            frozen_size=$stdin_window_size
            echo "$frozen_size" > "$ctx_file"
        fi
        if [[ "$frozen_size" -gt 0 ]]; then
            local used_tokens
            used_tokens=$(echo "$input" | jq -r '
                (.context_window.current_usage.input_tokens // 0) +
                (.context_window.current_usage.output_tokens // 0) +
                (.context_window.current_usage.cache_creation_input_tokens // 0) +
                (.context_window.current_usage.cache_read_input_tokens // 0)
            ')
            echo $(( used_tokens * 100 / frozen_size ))
            return
        fi
    fi

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

    [[ ! -f "$USAGE_CACHE_FILE" ]] && return 0
    (( cache_age <= USAGE_CACHE_MAX_AGE )) && return 1
    return 0
}

log_event() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') $1" >> "$USAGE_LOG_FILE" 2>/dev/null
}

set_error() {
    echo "$1" > "$USAGE_ERROR_FILE" 2>/dev/null || true
}

clear_error() {
    rm -f "$USAGE_ERROR_FILE" 2>/dev/null || true
}

chrome_is_running() {
    pgrep -x "Google Chrome" >/dev/null 2>&1
}

find_claude_tab_and_execute_js() {
    local js=$1
    osascript -e "
    tell application \"Google Chrome\"
        repeat with w in windows
            repeat with t in tabs of w
                if URL of t contains \"claude.ai\" then
                    return (execute t javascript \"$js\")
                end if
            end repeat
        end repeat
    end tell
    " 2>&1
}

open_claude_tab() {
    if chrome_is_running; then
        osascript -e 'tell application "Google Chrome" to open location "https://claude.ai"' 2>/dev/null || true
    else
        open -a "Google Chrome" "https://claude.ai" 2>/dev/null || true
    fi
}

fetch_usage_via_chrome() {
    if ! chrome_is_running; then
        log_event "chrome: not running"
        set_error "open Chrome"
        return 1
    fi

    local result
    result=$(find_claude_tab_and_execute_js "
        var xhr = new XMLHttpRequest();
        xhr.open(\\\"GET\\\", \\\"/api/organizations\\\", false);
        xhr.send();
        if (xhr.status !== 200) throw \\\"orgs: \\\" + xhr.status;
        var orgId = JSON.parse(xhr.responseText)[0].uuid;
        var xhr2 = new XMLHttpRequest();
        xhr2.open(\\\"GET\\\", \\\"/api/organizations/\\\" + orgId + \\\"/usage\\\", false);
        xhr2.send();
        if (xhr2.status !== 200) throw \\\"usage: \\\" + xhr2.status;
        xhr2.responseText;
    ")

    if echo "$result" | grep -q "Executing JavaScript through AppleScript is turned off"; then
        log_event "chrome: JS from Apple Events disabled"
        set_error "enable Chrome JS"
        return 1
    fi

    if [[ -z "$result" ]]; then
        log_event "chrome: no claude.ai tab found"
        set_error "open claude.ai"
        open_claude_tab
        return 1
    fi

    if echo "$result" | jq -e '.five_hour' >/dev/null 2>&1; then
        echo "$result"
        return 0
    fi

    log_event "chrome: unexpected response - ${result:0:100}"
    set_error "API error"
    return 1
}

fetch_usage_limits() {
    local response
    response=$(fetch_usage_via_chrome) || return 1

    log_event "chrome: success"
    clear_error
    echo "$response" > "$USAGE_CACHE_FILE"
    return 0
}

fetch_usage_limits_if_still_stale() {
    usage_cache_is_stale || return 0
    fetch_usage_limits || true
}

cleanup_stale_lock() {
    [[ -d "$USAGE_CACHE_LOCK_FILE" ]] || return 0
    local lock_age=$(( $(date +%s) - $(stat -f %m "$USAGE_CACHE_LOCK_FILE" 2>/dev/null || echo 0) ))
    (( lock_age > USAGE_CACHE_LOCK_STALE_AGE )) && rmdir "$USAGE_CACHE_LOCK_FILE" 2>/dev/null || true
}

with_fetch_lock() {
    cleanup_stale_lock
    local deadline=$(( $(date +%s) + USAGE_CACHE_LOCK_TIMEOUT ))
    until mkdir "$USAGE_CACHE_LOCK_FILE" 2>/dev/null; do
        (( $(date +%s) >= deadline )) && { "$@"; return; }
        sleep 0.2
    done
    trap 'rmdir "$USAGE_CACHE_LOCK_FILE" 2>/dev/null || true' EXIT
    "$@"
    rmdir "$USAGE_CACHE_LOCK_FILE" 2>/dev/null || true
    trap - EXIT
}

read_usage_from_cache() {
    [[ -f "$USAGE_CACHE_FILE" ]] || return 1
    (( $(date +%s) - $(stat -f %m "$USAGE_CACHE_FILE" 2>/dev/null || echo 0) > USAGE_CACHE_STALE_AGE )) && return 1
    jq -e '.five_hour' "$USAGE_CACHE_FILE" >/dev/null 2>&1 || return 1

    local five_hour seven_day sonnet five_hour_reset seven_day_reset sonnet_reset
    five_hour=$(jq -r '.five_hour.utilization // empty' "$USAGE_CACHE_FILE" 2>/dev/null | cut -d'.' -f1)
    seven_day=$(jq -r '.seven_day.utilization // empty' "$USAGE_CACHE_FILE" 2>/dev/null | cut -d'.' -f1)
    sonnet=$(jq -r '.seven_day_sonnet.utilization // empty' "$USAGE_CACHE_FILE" 2>/dev/null | cut -d'.' -f1)
    five_hour_reset=$(jq -r '.five_hour.resets_at // empty' "$USAGE_CACHE_FILE" 2>/dev/null)
    seven_day_reset=$(jq -r '.seven_day.resets_at // empty' "$USAGE_CACHE_FILE" 2>/dev/null)
    sonnet_reset=$(jq -r '.seven_day_sonnet.resets_at // empty' "$USAGE_CACHE_FILE" 2>/dev/null)
    echo "${five_hour:-}|${seven_day:-}|${sonnet:-}|${five_hour_reset:-}|${seven_day_reset:-}|${sonnet_reset:-}"
}

get_usage_limits() {
    if usage_cache_is_stale; then
        with_fetch_lock fetch_usage_limits_if_still_stale
    fi

    local result
    result=$(read_usage_from_cache) && { echo "$result"; return; }

    local error_msg=""
    if [[ -f "$USAGE_ERROR_FILE" ]]; then
        error_msg=$(cat "$USAGE_ERROR_FILE" 2>/dev/null)
    fi
    echo "error:${error_msg}|||||"
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
    local error_msg=${11:-}

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

    local status_part=""
    if [[ -n "$error_msg" ]]; then
        status_part=" ${COLOR_GRAY}│${COLOR_RESET} ${COLOR_YELLOW}⚠ ${error_msg}${COLOR_RESET}"
    fi

    echo -e "${model_part} ${COLOR_GRAY}│${COLOR_RESET} ${context_part} ${COLOR_GRAY}│${COLOR_RESET} ${five_hour_part} ${COLOR_GRAY}│${COLOR_RESET} ${seven_day_part} ${COLOR_GRAY}│${COLOR_RESET} ${sonnet_part} ${COLOR_GRAY}│${COLOR_RESET} ${cost_part} ${COLOR_GRAY}│${COLOR_RESET} ${duration_part}${status_part}"
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
    echo ""
    echo "Error state:"
    format_output "45" "Opus" "" "" "" "" "" "" "0.01" "60000" "open claude.ai"
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
    local error_msg=""
    if [[ "${usage_data%%|*}" == error:* ]]; then
        error_msg="${usage_data%%|*}"
        error_msg="${error_msg#error:}"
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

    format_output "$used" "$model" "$five_hour" "$seven_day" "$sonnet" "$five_hour_reset" "$seven_day_reset" "$sonnet_reset" "$cost" "$duration_ms" "$error_msg"
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
