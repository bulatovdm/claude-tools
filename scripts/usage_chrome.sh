#!/bin/bash

# Chrome-based usage fetcher (legacy)
# Sourced by statusline.sh — do not run directly
# Fetches rate limits from claude.ai via Chrome AppleScript

: "${USAGE_CACHE_FILE:="/tmp/claude-statusline-usage-cache"}"
: "${USAGE_CACHE_LOCK_FILE:="/tmp/claude-statusline-usage-lock"}"
: "${USAGE_ERROR_FILE:="/tmp/claude-statusline-error"}"
: "${USAGE_LOG_FILE:="/tmp/claude-statusline.log"}"
: "${USAGE_CACHE_MAX_AGE:=300}"
: "${USAGE_CACHE_STALE_AGE:=600}"
: "${USAGE_CACHE_LOCK_TIMEOUT:=10}"
: "${USAGE_CACHE_LOCK_STALE_AGE:=60}"

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

get_usage_limits_chrome() {
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
