#!/bin/bash

# Native usage parser — extracts rate_limits from Claude Code stdin JSON
# Sourced by statusline.sh — do not run directly
# Available since Claude Code v2.1.80

unix_to_iso() {
    local timestamp=$1
    [[ -z "$timestamp" || "$timestamp" == "null" || "$timestamp" == "0" ]] && return 1
    TZ=UTC date -r "$timestamp" +"%Y-%m-%dT%H:%M:%S" 2>/dev/null || return 1
}

get_usage_limits_native() {
    local input=$1

    local five_hour seven_day
    local five_hour_reset_unix seven_day_reset_unix
    local five_hour_reset seven_day_reset

    five_hour=$(echo "$input" | jq -r '.rate_limits.five_hour.used_percentage // empty' 2>/dev/null | cut -d'.' -f1)
    five_hour_reset_unix=$(echo "$input" | jq -r '.rate_limits.five_hour.resets_at // empty' 2>/dev/null)

    seven_day=$(echo "$input" | jq -r '.rate_limits.seven_day.used_percentage // empty' 2>/dev/null | cut -d'.' -f1)
    seven_day_reset_unix=$(echo "$input" | jq -r '.rate_limits.seven_day.resets_at // empty' 2>/dev/null)

    five_hour_reset=""
    if [[ -n "$five_hour_reset_unix" && "$five_hour_reset_unix" != "null" ]]; then
        five_hour_reset=$(unix_to_iso "$five_hour_reset_unix") || five_hour_reset=""
    fi

    seven_day_reset=""
    if [[ -n "$seven_day_reset_unix" && "$seven_day_reset_unix" != "null" ]]; then
        seven_day_reset=$(unix_to_iso "$seven_day_reset_unix") || seven_day_reset=""
    fi

    echo "${five_hour:-}|${seven_day:-}||${five_hour_reset:-}|${seven_day_reset:-}|"
}
