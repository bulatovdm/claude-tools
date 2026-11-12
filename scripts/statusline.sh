#!/bin/bash

set -euo pipefail

readonly SCRIPT_NAME=$(basename "$0")
readonly VERSION="7.1.0"

readonly COLOR_GREEN="\033[32m"
readonly COLOR_YELLOW="\033[33m"
readonly COLOR_RED="\033[31m"
readonly COLOR_GRAY="\033[90m"
readonly COLOR_CYAN="\033[36m"
readonly COLOR_RESET="\033[0m"

readonly BAR_WIDTH=15
readonly BAR_FILLED="█"
readonly BAR_EMPTY="░"

readonly THINKING_ICON="✻"

# Project extension point: a project adds its own lines under the status line
# by shipping an executable file at this path inside its root.
readonly PROJECT_SEGMENT_PATH=".claude/statusline-segment.sh"
# Only projects under a directory listed here (one path per line) may run it.
readonly TRUSTED_ROOTS_FILE="${STATUSLINE_TRUSTED_FILE:-$HOME/.claude/statusline-trusted}"

readonly SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# Durable per-session cache: /tmp is wiped on reboot, which would lose the
# thinking state needed to restore a session (it exists nowhere else on disk)
readonly SESSION_CACHE_DIR="${STATUSLINE_CACHE_DIR:-$HOME/.claude/statusline-cache}"

show_help() {
    cat << EOF
Usage: $SCRIPT_NAME [OPTIONS]

Claude Code status line with context bar, model, usage limits, cost, and work time.
Shows context usage, current model with thinking effort level, 5-hour and weekly limits,
session cost and how long the agent actually worked (duration of its turns).

Work time: sum of turn durations from the transcript's turn_duration records
(Esc-interrupted turns end at the interrupt marker) united with subagent
transcripts, so parallel agents do not multiply it; idle time between turns is
excluded. "now" is the running turn. Units: m, h, d (days), w (weeks).

Effort level comes from stdin (.effort.level): low, medium, high, xhigh, max.
Prefixed with $THINKING_ICON while thinking is enabled (.thinking.enabled).
Both values are cached per session; if a render omits them, the last value
seen in that same session is reused instead of another session's leftover.
Stdin always wins: it reports what Claude Code will actually use. On resume,
session.sh (cs) restores the session's own effort/thinking into settings.json
before launch, so stdin stays truthful. The transcript is only a fallback for
Claude Code versions that don't send the effort field at all.

5h and weekly limits come only from the native rate_limits that Anthropic sends
on stdin (Claude Code v2.1.80+). Nothing else is queried: no browser, no network.

Project segment: if the project directory (.workspace.project_dir, else .cwd)
contains an executable $PROJECT_SEGMENT_PATH and lies under a directory
listed in $TRUSTED_ROOTS_FILE, the segment is run with the same stdin JSON and
its output is printed below the status line. A failing or missing segment, or
a project outside the trusted roots, prints nothing.

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
    elif (( percentage < 90 )); then
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

read_session_cache() {
    local session_id=$1
    local kind=$2

    [[ -z "$session_id" ]] && return 0

    local cache_file="$SESSION_CACHE_DIR/${kind}-${session_id}"
    if [[ -f "$cache_file" ]]; then
        cat "$cache_file"
        return 0
    fi

    # Legacy location before the cache moved out of /tmp
    local legacy_file="/tmp/claude-${kind}-${session_id}"
    if [[ -f "$legacy_file" ]]; then
        cat "$legacy_file"
    fi
    return 0
}

write_session_cache() {
    local session_id=$1
    local kind=$2
    local value=$3

    [[ -z "$session_id" ]] && return 0
    mkdir -p "$SESSION_CACHE_DIR" 2>/dev/null || return 0
    echo "$value" > "$SESSION_CACHE_DIR/${kind}-${session_id}"
}

find_session_transcript() {
    local input=$1
    local session_id=$2

    [[ -z "$session_id" ]] && return 0

    local transcript
    transcript=$(echo "$input" | jq -r '.transcript_path // empty')
    if [[ -n "$transcript" && -f "$transcript" ]]; then
        echo "$transcript"
        return 0
    fi

    local projects_dir="$HOME/.claude/projects"
    [[ -d "$projects_dir" ]] || return 0

    local match
    match=$(find "$projects_dir" -maxdepth 2 -name "${session_id}.jsonl" -type f 2>/dev/null | head -1)
    [[ -n "$match" ]] && echo "$match"
    return 0
}

read_effort_from_transcript() {
    local transcript=$1

    [[ -f "$transcript" ]] || return 0

    grep -o '"effort":"[a-z]*"' "$transcript" 2>/dev/null \
        | tail -1 \
        | sed 's/.*:"//; s/"$//'
    return 0
}

parse_effort_level() {
    local input=$1
    local session_id
    session_id=$(echo "$input" | jq -r '.session_id // empty')

    local level
    level=$(echo "$input" | jq -r '.effort.level // empty')

    # Stdin reports what Claude Code will actually use for the next prompt, so
    # it always wins — session.sh restores the session's own state into
    # settings.json before resume, keeping stdin truthful. The transcript is
    # only a last resort for versions that don't send the field at all.
    if [[ -n "$level" ]]; then
        write_session_cache "$session_id" "effort" "$level"
        echo "$level"
        return 0
    fi

    local cached
    cached=$(read_session_cache "$session_id" "effort")
    if [[ -n "$cached" ]]; then
        echo "$cached"
        return 0
    fi

    local transcript
    transcript=$(find_session_transcript "$input" "$session_id")

    local from_transcript=""
    [[ -n "$transcript" ]] && from_transcript=$(read_effort_from_transcript "$transcript")

    if [[ -n "$from_transcript" ]]; then
        write_session_cache "$session_id" "effort" "$from_transcript"
        echo "$from_transcript"
    fi
    return 0
}

parse_thinking_enabled() {
    local input=$1
    local session_id
    session_id=$(echo "$input" | jq -r '.session_id // empty')

    local enabled
    enabled=$(echo "$input" | jq -r '
        if (.thinking | type) == "object" and (.thinking.enabled | type) == "boolean"
        then (if .thinking.enabled then "1" else "0" end)
        else "" end
    ')

    # Unlike effort, thinking state is not recorded per session anywhere on disk,
    # so there is nothing to restore it from on resume. Report only what stdin
    # says, falling back to the last value seen in this same session.
    if [[ -n "$enabled" ]]; then
        write_session_cache "$session_id" "thinking" "$enabled"
    else
        enabled=$(read_session_cache "$session_id" "thinking")
    fi

    if [[ "$enabled" == "1" ]]; then
        echo "1"
    fi
}

get_color_by_effort_level() {
    local level=$1

    case "$level" in
        xhigh|max) echo "$COLOR_YELLOW" ;;
        high)      echo "$COLOR_CYAN" ;;
        *)         echo "$COLOR_GRAY" ;;
    esac
}

format_effort_part() {
    local level=$1
    local thinking_enabled=${2:-}

    [[ -z "$level" ]] && return

    local color
    color=$(get_color_by_effort_level "$level")

    local icon=""
    [[ -n "$thinking_enabled" ]] && icon="$THINKING_ICON"

    echo -e "${color}${icon}${level}${COLOR_RESET}"
}

parse_cost() {
    local input=$1
    echo "$input" | jq -r '.cost.total_cost_usd // 0'
}

# Two largest units: 12m, 3h 5m, 2d 4h, 3w 1d
format_seconds() {
    local total_sec=$1
    local weeks=$((total_sec / 604800))
    local days=$(((total_sec % 604800) / 86400))
    local hours=$(((total_sec % 86400) / 3600))
    local mins=$(((total_sec % 3600) / 60))

    if (( weeks > 0 )); then
        echo "${weeks}w ${days}d"
    elif (( days > 0 )); then
        echo "${days}d ${hours}h"
    elif (( hours > 0 )); then
        echo "${hours}h ${mins}m"
    else
        echo "${mins}m"
    fi
}

# Folds new transcript lines into {intervals, open}: closed turns come from
# turn_duration records (Esc-interrupted turns get none, so they close at the
# interrupt marker); "open" is the start of the turn still running.
readonly WORK_TURNS_JQ='
def epoch: sub("\\.[0-9]+Z$"; "Z") | fromdate;
def text_of: .message.content
    | if type == "string" then .
      elif type == "array" then map(select(.type == "text") | .text) | join("")
      else "" end;
def is_interrupt: text_of | startswith("[Request interrupted by user");
def is_turn_start: .isMeta != true and .isCompactSummary != true
    and (text_of | . != "" and (test("^\\s*<(command-|local-command)") | not));
reduce (inputs | fromjson? | select(.isSidechain != true and .timestamp != null)) as $e ($state[0];
    ($e.timestamp | epoch) as $t
    | if $e.subtype == "turn_duration" then
        .intervals += [[$t - ($e.durationMs / 1000), $t]] | .open = null
      elif $e.type != "user" then .
      elif ($e | is_interrupt) then
        (if .open then .intervals += [[.open, $t]] else . end) | .open = null
      elif ($e | is_turn_start) then .open = $t
      else . end)
| .intervals |= unique
| .size = $size'

# Union of all intervals, so parallel agents do not multiply the time
readonly WORK_SUMMARY_JQ='
def epoch: sub("\\.[0-9]+Z$"; "Z") | fromdate;
($state[0] // {intervals: [], open: null}) as $main
| [$subagents | split("\n")[] | select(length > 0) | split("\t")
    | select(length == 3) | [(.[1] | epoch), (.[2] | epoch)]] as $sub
| ($main.intervals + $sub
    + (if $main.open then [[$main.open, $now]] else [] end))
| map(select(.[1] > .[0])) | sort_by(.[0])
| reduce .[] as $i ({total: 0, end: null};
    if .end == null or $i[0] >= .end then .total += ($i[1] - $i[0]) | .end = $i[1]
    elif $i[1] > .end then .total += ($i[1] - .end) | .end = $i[1]
    else . end)
| "\(.total | floor)|\(if $main.open then ($now - $main.open | floor) else "" end)"'

readonly WORK_BACKGROUND_SCAN_BYTES=20000000
readonly WORK_RESCAN_OVERLAP_BYTES=1048576
readonly ISO_TIMESTAMP_PATTERN='"timestamp":"[^"]*"'

file_size() {
    stat -f %z "$1" 2>/dev/null || stat -c %s "$1" 2>/dev/null || echo 0
}

extract_relevant_turn_lines() {
    grep -E '"subtype":"turn_duration"|"type":"user"' | grep -vF '"type":"tool_result"' || true
}

# Re-reads an overlap before the last scanned size: a line that was still
# being written then is read whole now. Replayed events are harmless, the
# fold is order-preserving and intervals are deduplicated.
update_main_turns_cache() {
    local transcript=$1
    local cache_file=$2
    local current_size=$3
    local scanned_size=0

    if [[ -f "$cache_file" ]]; then
        scanned_size=$(jq -r '.size // 0' "$cache_file" 2>/dev/null || echo 0)
    fi
    (( current_size == scanned_size )) && return 0

    local state_file
    state_file=$(mktemp "${cache_file}.XXXXXX")
    if (( current_size < scanned_size )) || [[ ! -f "$cache_file" ]]; then
        scanned_size=0
        echo '{"intervals":[],"open":null,"size":0}' > "$state_file"
    else
        cp "$cache_file" "$state_file"
    fi

    local resume_offset=$((scanned_size - WORK_RESCAN_OVERLAP_BYTES))
    (( resume_offset < 0 )) && resume_offset=0

    if read_transcript_from "$transcript" "$resume_offset" \
        | extract_relevant_turn_lines \
        | jq -nR --slurpfile state "$state_file" --argjson size "$current_size" "$WORK_TURNS_JQ" \
            > "${state_file}.new" 2>/dev/null; then
        mv "${state_file}.new" "$cache_file"
    else
        rm -f "${state_file}.new"
    fi
    rm -f "$state_file"
}

read_transcript_from() {
    local transcript=$1
    local offset=$2

    if (( offset == 0 )); then
        cat "$transcript"
    else
        tail -c +$((offset + 1)) "$transcript"
    fi
}

first_and_last_timestamp() {
    local file=$1
    local first last
    first=$(grep -m1 -o "$ISO_TIMESTAMP_PATTERN" "$file" 2>/dev/null | head -1 | cut -d'"' -f4) || true
    last=$(tail -c 65536 "$file" | grep -o "$ISO_TIMESTAMP_PATTERN" 2>/dev/null | tail -1 | cut -d'"' -f4) || true
    [[ -n "$first" && -n "$last" ]] && printf '%s\t%s\n' "$first" "$last"
    return 0
}

keep_rows_of_existing_files() {
    local dir=$1
    local row
    while IFS= read -r row; do
        [[ -f "$dir/${row%%$'\t'*}" ]] && printf '%s\n' "$row"
    done
    return 0
}

update_subagent_cache() {
    local subagent_dir=$1
    local cache_file=$2

    if [[ ! -d "$subagent_dir" ]]; then
        rm -f "$cache_file"
        return 0
    fi

    local changed
    if [[ -f "$cache_file" ]]; then
        changed=$(find "$subagent_dir" -maxdepth 1 -name 'agent-*.jsonl' -newer "$cache_file" 2>/dev/null)
    else
        changed=$(find "$subagent_dir" -maxdepth 1 -name 'agent-*.jsonl' 2>/dev/null)
    fi
    [[ -z "$changed" ]] && return 0

    local updated
    updated=$(mktemp "${cache_file}.XXXXXX")
    {
        [[ -f "$cache_file" ]] && cat "$cache_file"
        local file span
        while IFS= read -r file; do
            span=$(first_and_last_timestamp "$file")
            [[ -n "$span" ]] && printf '%s\t%s\n' "$(basename "$file")" "$span"
        done <<< "$changed"
    } | awk -F'\t' '{ row[$1] = $0; if (!($1 in seen)) { seen[$1] = 1; order[++n] = $1 } }
        END { for (i = 1; i <= n; i++) print row[order[i]] }' \
        | keep_rows_of_existing_files "$subagent_dir" > "$updated"
    mv "$updated" "$cache_file"
}

refresh_work_caches() {
    local transcript=$1
    local session_id=$2
    local main_cache="$SESSION_CACHE_DIR/work-${session_id}.json"
    local subagent_cache="$SESSION_CACHE_DIR/work-subagents-${session_id}"
    local current_size scanned_size=0

    current_size=$(file_size "$transcript")
    [[ -f "$main_cache" ]] && scanned_size=$(jq -r '.size // 0' "$main_cache" 2>/dev/null || echo 0)

    if (( current_size - scanned_size > WORK_BACKGROUND_SCAN_BYTES )); then
        local lock_dir="$SESSION_CACHE_DIR/work-${session_id}.lock"
        if mkdir "$lock_dir" 2>/dev/null; then
            (
                update_main_turns_cache "$transcript" "$main_cache" "$current_size"
                rmdir "$lock_dir"
            ) < /dev/null > /dev/null 2>&1 &
        fi
    else
        update_main_turns_cache "$transcript" "$main_cache" "$current_size"
    fi
    update_subagent_cache "${transcript%.jsonl}/subagents" "$subagent_cache"
}

# Output: "total_seconds|current_turn_seconds"; current is empty between turns
get_work_time() {
    local input=$1
    local session_id transcript

    session_id=$(echo "$input" | jq -r '.session_id // empty')
    transcript=$(find_session_transcript "$input" "$session_id")
    [[ -n "$transcript" ]] || return 0
    mkdir -p "$SESSION_CACHE_DIR" 2>/dev/null || return 0

    refresh_work_caches "$transcript" "$session_id"

    local main_cache="$SESSION_CACHE_DIR/work-${session_id}.json"
    [[ -f "$main_cache" ]] || return 0
    local subagents=""
    [[ -f "$SESSION_CACHE_DIR/work-subagents-${session_id}" ]] \
        && subagents=$(cat "$SESSION_CACHE_DIR/work-subagents-${session_id}")

    jq -nr --slurpfile state "$main_cache" --arg subagents "$subagents" \
        --argjson now "$(date +%s)" "$WORK_SUMMARY_JQ" 2>/dev/null || true
}

format_work_part() {
    local work_time=$1
    local total current

    if [[ -z "$work_time" ]]; then
        echo -e "${COLOR_GRAY}Work: ?${COLOR_RESET}"
        return 0
    fi
    IFS='|' read -r total current <<< "$work_time"

    local part="${COLOR_GRAY}Work:${COLOR_RESET} $(format_seconds "$total")"
    [[ -n "$current" ]] && part="${part} ${COLOR_GRAY}· now:${COLOR_RESET} $(format_seconds "$current")"
    echo -e "$part"
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

get_usage_limits() {
    local input=$1

    source "${SCRIPT_DIR}/usage_native.sh"
    get_usage_limits_native "$input"
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
    local five_hour_reset=$5
    local seven_day_reset=$6
    local cost=$7
    local work_time=$8
    local effort_level=${9:-}
    local thinking_enabled=${10:-}

    local used_color
    local used_bar
    used_color=$(get_color_by_percentage "$used")
    used_bar=$(build_progress_bar "$used" "$used_color")

    local context_part="${COLOR_GRAY}Context:${COLOR_RESET} ${used_bar} ${used_color}${used}%${COLOR_RESET}"
    local model_part="${COLOR_CYAN}${model}${COLOR_RESET}"

    local effort_str
    effort_str=$(format_effort_part "$effort_level" "$thinking_enabled")
    [[ -n "$effort_str" ]] && model_part="${model_part} ${effort_str}"

    local five_hour_part
    local seven_day_part
    five_hour_part=$(format_usage_part "5h" "$five_hour" "$five_hour_reset" "18000")
    seven_day_part=$(format_usage_part "Week" "$seven_day" "$seven_day_reset" "604800")

    local cost_part="${COLOR_GRAY}Cost:${COLOR_RESET} ${COLOR_YELLOW}$(format_cost "$cost")${COLOR_RESET}"
    local work_part
    work_part=$(format_work_part "$work_time")

    echo -e "${model_part} ${COLOR_GRAY}│${COLOR_RESET} ${context_part} ${COLOR_GRAY}│${COLOR_RESET} ${five_hour_part} ${COLOR_GRAY}│${COLOR_RESET} ${seven_day_part} ${COLOR_GRAY}│${COLOR_RESET} ${cost_part} ${COLOR_GRAY}│${COLOR_RESET} ${work_part}"
}

run_test() {
    echo "Test output at different usage levels:"
    echo ""
    # Generate test reset times relative to now
    local now_epoch
    now_epoch=$(date +%s)
    local reset_2h reset_6d
    reset_2h=$(TZ=UTC date -r $((now_epoch + 7200)) +"%Y-%m-%dT%H:%M:%S" 2>/dev/null || echo "")
    reset_6d=$(TZ=UTC date -r $((now_epoch + 518400)) +"%Y-%m-%dT%H:%M:%S" 2>/dev/null || echo "")

    echo "Low usage (45%), short session:"
    format_output "45" "Opus" "6" "35" "$reset_2h" "$reset_6d" "0.42" "300|" "xhigh" "1"
    echo ""
    echo "Medium usage (70%), longer session:"
    format_output "70" "Sonnet" "50" "60" "$reset_2h" "$reset_6d" "2.15" "93780|420" "high" "1"
    echo ""
    echo "High usage (85%), expensive session:"
    format_output "85" "Opus" "80" "90" "$reset_2h" "$reset_6d" "8.73" "1900800|60" "max" "1"
    echo ""
    echo "Effort levels:"
    for level in low medium high xhigh max; do
        format_output "45" "Opus" "6" "35" "$reset_2h" "$reset_6d" "0.42" "300|" "$level" "1"
    done
    echo ""
    echo "Thinking disabled:"
    format_output "45" "Opus" "6" "35" "$reset_2h" "$reset_6d" "0.42" "300|" "medium" ""
    echo ""
    echo "No limits data:"
    format_output "45" "Opus" "" "" "" "" "0.01" ""
}

project_is_trusted() {
    local project_dir=$1
    local root

    [[ -r "$TRUSTED_ROOTS_FILE" ]] || return 1
    while IFS= read -r root || [[ -n "$root" ]]; do
        root="${root%/}"
        [[ -n "$root" && "$root" != \#* ]] || continue
        [[ "$project_dir" == "$root" || "$project_dir" == "$root"/* ]] && return 0
    done < "$TRUSTED_ROOTS_FILE"
    return 1
}

print_project_segment() {
    local input=$1
    local project_dir
    local segment

    project_dir=$(printf '%s' "$input" | jq -r '.workspace.project_dir // .cwd // empty' 2>/dev/null) || return 0
    [[ -n "$project_dir" ]] || return 0
    project_is_trusted "$project_dir" || return 0
    segment="$project_dir/$PROJECT_SEGMENT_PATH"
    [[ -x "$segment" ]] || return 0
    printf '%s' "$input" | "$segment" 2>/dev/null || true
}

main() {
    local input
    local used
    local model
    local cost
    local work_time
    local usage_data
    local five_hour
    local seven_day
    local five_hour_reset
    local seven_day_reset
    local effort_level
    local thinking_enabled

    input=$(cat)
    used=$(parse_used_percentage "$input")
    model=$(parse_model_name "$input")
    effort_level=$(parse_effort_level "$input")
    thinking_enabled=$(parse_thinking_enabled "$input")
    cost=$(parse_cost "$input")
    work_time=$(get_work_time "$input")

    usage_data=$(get_usage_limits "$input")
    IFS='|' read -r five_hour seven_day five_hour_reset seven_day_reset <<< "$usage_data"

    format_output "$used" "$model" "$five_hour" "$seven_day" "$five_hour_reset" "$seven_day_reset" "$cost" "$work_time" "$effort_level" "$thinking_enabled"
    print_project_segment "$input"
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
