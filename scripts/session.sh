#!/bin/bash

set -euo pipefail

readonly SCRIPT_NAME=$(basename "$0")
readonly VERSION="1.0.0"
readonly HISTORY_FILE="$HOME/.claude/history.jsonl"
readonly PROJECTS_DIR="$HOME/.claude/projects"

readonly COLOR_GREEN="\033[32m"
readonly COLOR_YELLOW="\033[33m"
readonly COLOR_RED="\033[31m"
readonly COLOR_CYAN="\033[36m"
readonly COLOR_DIM="\033[2m"
readonly COLOR_BOLD="\033[1m"
readonly COLOR_RESET="\033[0m"

show_help() {
    cat << EOF
Usage: $SCRIPT_NAME [OPTIONS]

Interactive session picker for Claude Code.
Reads ~/.claude/history.jsonl, groups by session, shows an interactive list.

Options:
    -a, --all           Show sessions from all projects
    -p, --project PATH  Show sessions for a specific project path
    -n, --limit N       Max sessions to show (default: 30)
    -l, --list          List sessions without interactive picker
    -h, --help          Show this help message
    -v, --version       Show version

Without flags, shows sessions for the current directory.

Examples:
    $SCRIPT_NAME                    # sessions for current project
    $SCRIPT_NAME --all              # all sessions across projects
    $SCRIPT_NAME --list             # non-interactive list
    $SCRIPT_NAME -n 50              # show up to 50 sessions

EOF
}

show_version() {
    echo "$SCRIPT_NAME version $VERSION"
}

die() {
    echo -e "${COLOR_RED}Error:${COLOR_RESET} $1" >&2
    exit 1
}

check_requirements() {
    if ! command -v jq &>/dev/null; then
        die "jq is required. Install: brew install jq"
    fi
    if [[ ! -f "$HISTORY_FILE" ]]; then
        die "History file not found: $HISTORY_FILE"
    fi
}

build_session_list() {
    local filter_project="${1:-}"
    local limit="${2:-30}"

    jq -r --arg proj "$filter_project" '
        select(.sessionId != null and .sessionId != "")
        | select(
            ($proj == "") or
            (.project // "" | contains($proj))
        )
        | [.sessionId, (.timestamp | tostring), (.project // ""), (.display // "" | gsub("\n"; " ") | if length > 80 then .[:80] + "…" else . end)]
        | @tsv
    ' "$HISTORY_FILE" | awk -F'\t' '
    {
        sid = $1
        ts = $2
        proj = $3
        display = $4

        if (!(sid in first_ts) || ts + 0 < first_ts[sid] + 0) {
            first_ts[sid] = ts
        }
        if (!(sid in last_ts) || ts + 0 > last_ts[sid] + 0) {
            last_ts[sid] = ts
        }
        count[sid]++
        projects[sid] = proj

        if (!(sid in preview)) {
            if (display != "" && display != "/exit" && display != "/clear" && display != "/resume" && length(display) > 3) {
                preview[sid] = display
            }
        }
        if (display != "" && display != "/exit" && display != "/clear" && display != "/resume" && length(display) > 3) {
            if (!(sid in best_preview) || length(display) > length(best_preview[sid])) {
                if (length(display) > 5) {
                    best_preview[sid] = display
                }
            }
        }
    }
    END {
        for (sid in first_ts) {
            p = best_preview[sid]
            if (p == "") p = preview[sid]
            if (p == "") p = "(no preview)"
            printf "%s\t%s\t%s\t%d\t%s\t%s\n", last_ts[sid], first_ts[sid], sid, count[sid], projects[sid], p
        }
    }
    ' | sort -t$'\t' -k1 -rn | awk -v max="$limit" 'NR <= max'
}

format_timestamp() {
    local ts_ms="$1"
    local ts_sec=$((ts_ms / 1000))
    if [[ "$(uname)" == "Darwin" ]]; then
        date -r "$ts_sec" "+%Y-%m-%d %H:%M" 2>/dev/null || echo "unknown"
    else
        date -d "@$ts_sec" "+%Y-%m-%d %H:%M" 2>/dev/null || echo "unknown"
    fi
}

format_duration() {
    local first_ms="$1"
    local last_ms="$2"
    local diff_sec=$(( (last_ms - first_ms) / 1000 ))

    if [[ $diff_sec -lt 60 ]]; then
        echo "<1m"
    elif [[ $diff_sec -lt 3600 ]]; then
        echo "$((diff_sec / 60))m"
    else
        local h=$((diff_sec / 3600))
        local m=$(( (diff_sec % 3600) / 60 ))
        echo "${h}h${m}m"
    fi
}

extract_project_name() {
    local full_path="$1"
    basename "$full_path" 2>/dev/null || echo "$full_path"
}

load_session_titles() {
    local session_ids_str="$1"

    local IFS=','
    for sid in $session_ids_str; do
        local session_file
        session_file=$(find "$PROJECTS_DIR" -name "${sid}.jsonl" -print -quit 2>/dev/null)
        if [[ -n "$session_file" ]]; then
            local title
            title=$(grep -o '"customTitle":"[^"]*"' "$session_file" 2>/dev/null | head -1 | sed 's/"customTitle":"//;s/"$//')
            if [[ -n "$title" ]]; then
                printf '%s\t%s\n' "$sid" "$title"
            fi
        fi
    done
}

display_sessions() {
    local filter_project="$1"
    local limit="$2"
    local interactive="$3"

    local data
    data=$(build_session_list "$filter_project" "$limit")

    if [[ -z "$data" ]]; then
        echo -e "${COLOR_YELLOW}No sessions found.${COLOR_RESET}"
        if [[ -n "$filter_project" ]]; then
            echo -e "${COLOR_DIM}Project filter: $filter_project${COLOR_RESET}"
            echo -e "${COLOR_DIM}Try: $SCRIPT_NAME --all${COLOR_RESET}"
        fi
        exit 0
    fi

    local all_sids=""
    while IFS=$'\t' read -r _lt _ft sid _rest; do
        if [[ -n "$all_sids" ]]; then
            all_sids="${all_sids},${sid}"
        else
            all_sids="$sid"
        fi
    done <<< "$data"

    local titles_data
    titles_data=$(load_session_titles "$all_sids")

    local raw_dates=()
    local raw_durations=()
    local raw_msg_counts=()
    local raw_projects=()
    local raw_titles=()
    local raw_previews=()
    SESSION_IDS=()
    DISPLAY_LINES=()

    local max_title_len=0
    local max_proj_len=0

    while IFS=$'\t' read -r last_ts first_ts sid msg_count project preview; do
        SESSION_IDS+=("$sid")
        raw_dates+=("$(format_timestamp "$last_ts")")
        raw_durations+=("$(format_duration "$first_ts" "$last_ts")")
        raw_msg_counts+=("$msg_count")
        raw_projects+=("$(extract_project_name "$project")")

        local title=""
        if [[ -n "$titles_data" ]]; then
            title=$(echo "$titles_data" | awk -F'\t' -v s="$sid" '$1 == s { print $2; exit }')
        fi
        raw_titles+=("$title")

        preview="${preview//[$'\r\n']/ }"
        preview="${preview#"${preview%%[![:space:]]*}"}"
        raw_previews+=("$preview")

        if [[ ${#title} -gt $max_title_len ]]; then
            max_title_len=${#title}
        fi
        local pn
        pn=$(extract_project_name "$project")
        if [[ ${#pn} -gt $max_proj_len ]]; then
            max_proj_len=${#pn}
        fi
    done <<< "$data"

    if [[ $max_title_len -gt 35 ]]; then
        max_title_len=35
    fi
    if [[ $max_proj_len -gt 25 ]]; then
        max_proj_len=25
    fi

    local fixed_cols_width=34
    if [[ -z "$filter_project" ]]; then
        fixed_cols_width=$((fixed_cols_width + max_proj_len + 2))
    fi
    if [[ $max_title_len -gt 0 ]]; then
        fixed_cols_width=$((fixed_cols_width + max_title_len + 2))
    fi

    local term_width
    term_width=$(tput cols 2>/dev/null || echo 120)
    local preview_width=$((term_width - fixed_cols_width - 6))
    if [[ $preview_width -lt 20 ]]; then
        preview_width=20
    fi
    if [[ $preview_width -gt 80 ]]; then
        preview_width=80
    fi

    local i
    for i in "${!SESSION_IDS[@]}"; do
        local title="${raw_titles[$i]}"
        local preview="${raw_previews[$i]}"

        if [[ ${#title} -gt $max_title_len && $max_title_len -gt 0 ]]; then
            title="${title:0:$((max_title_len - 1))}…"
        fi

        if [[ ${#preview} -gt $preview_width ]]; then
            preview="${preview:0:$((preview_width - 1))}…"
        fi

        local line
        if [[ -n "$filter_project" ]]; then
            if [[ $max_title_len -gt 0 ]]; then
                line=$(printf "%-16s %7s %4d msgs  %-${max_title_len}s  %s" "${raw_dates[$i]}" "${raw_durations[$i]}" "${raw_msg_counts[$i]}" "$title" "$preview")
            else
                line=$(printf "%-16s %7s %4d msgs  %s" "${raw_dates[$i]}" "${raw_durations[$i]}" "${raw_msg_counts[$i]}" "$preview")
            fi
        else
            if [[ $max_title_len -gt 0 ]]; then
                line=$(printf "%-16s %7s %4d msgs  %-${max_proj_len}s  %-${max_title_len}s  %s" "${raw_dates[$i]}" "${raw_durations[$i]}" "${raw_msg_counts[$i]}" "${raw_projects[$i]}" "$title" "$preview")
            else
                line=$(printf "%-16s %7s %4d msgs  %-${max_proj_len}s  %s" "${raw_dates[$i]}" "${raw_durations[$i]}" "${raw_msg_counts[$i]}" "${raw_projects[$i]}" "$preview")
            fi
        fi
        DISPLAY_LINES+=("$line")
    done

    local total=${#SESSION_IDS[@]}

    if [[ "$interactive" != "true" ]]; then
        echo -e "${COLOR_BOLD}Sessions${COLOR_RESET} ${COLOR_DIM}($total)${COLOR_RESET}"
        echo ""
        for i in "${!DISPLAY_LINES[@]}"; do
            local num=$((i + 1))
            printf "${COLOR_DIM}%2d${COLOR_RESET}  %s\n" "$num" "${DISPLAY_LINES[$i]}"
        done
        echo ""
        echo -e "${COLOR_DIM}Resume: claude --resume <session-id>${COLOR_RESET}"
        return 0
    fi

    if command -v fzf &>/dev/null; then
        pick_with_fzf "$total"
    else
        pick_with_select "$total"
    fi
}

pick_with_fzf() {
    local total="$1"

    local fzf_input=""
    local i
    for i in "${!DISPLAY_LINES[@]}"; do
        fzf_input+="${SESSION_IDS[$i]}"$'\t'"${DISPLAY_LINES[$i]}"$'\n'
    done

    local selected
    selected=$(echo -n "$fzf_input" | fzf \
        --header="Select session (Enter to resume, Esc to cancel)" \
        --delimiter=$'\t' \
        --with-nth=2 \
        --no-multi \
        --height=~40% \
        --reverse \
        --ansi \
        2>/dev/null) || return 0

    local sid
    sid=$(echo "$selected" | cut -f1)

    if [[ -n "$sid" ]]; then
        echo -e "${COLOR_GREEN}Resuming session:${COLOR_RESET} ${COLOR_DIM}$sid${COLOR_RESET}"
        exec claude --resume "$sid"
    fi
}

pick_with_select() {
    local total="$1"

    echo -e "${COLOR_BOLD}Sessions${COLOR_RESET} ${COLOR_DIM}($total)${COLOR_RESET}"
    echo ""

    local i
    for i in "${!DISPLAY_LINES[@]}"; do
        local num=$((i + 1))
        printf "  ${COLOR_CYAN}%2d${COLOR_RESET}  %s\n" "$num" "${DISPLAY_LINES[$i]}"
    done

    echo ""
    echo -ne "${COLOR_BOLD}Enter number (or q to quit): ${COLOR_RESET}"
    read -r choice

    if [[ "$choice" == "q" || "$choice" == "" ]]; then
        return 0
    fi

    if ! [[ "$choice" =~ ^[0-9]+$ ]] || [[ "$choice" -lt 1 ]] || [[ "$choice" -gt "$total" ]]; then
        die "Invalid choice: $choice"
    fi

    local idx=$((choice - 1))
    local sid="${SESSION_IDS[$idx]}"

    echo -e "${COLOR_GREEN}Resuming session:${COLOR_RESET} ${COLOR_DIM}$sid${COLOR_RESET}"
    exec claude --resume "$sid"
}

main() {
    local filter_project=""
    local limit=30
    local interactive=true
    local show_all=false

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
            -a|--all)
                show_all=true
                shift
                ;;
            -p|--project)
                [[ -n "${2:-}" ]] || die "--project requires a path argument"
                filter_project="$2"
                shift 2
                ;;
            -n|--limit)
                [[ -n "${2:-}" ]] || die "--limit requires a number"
                limit="$2"
                shift 2
                ;;
            -l|--list)
                interactive=false
                shift
                ;;
            *)
                die "Unknown option: $1. Use --help for usage."
                ;;
        esac
    done

    check_requirements

    if [[ "$show_all" != "true" && -z "$filter_project" ]]; then
        filter_project="$(pwd)"
    fi

    display_sessions "$filter_project" "$limit" "$interactive"
}

main "$@"
