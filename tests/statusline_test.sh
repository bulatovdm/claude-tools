#!/bin/bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
STATUSLINE="$SCRIPT_DIR/scripts/statusline.sh"
NATIVE_MODULE="$SCRIPT_DIR/scripts/usage_native.sh"

PASS=0
FAIL=0

strip_colors() {
    sed 's/\x1b\[[0-9;]*m//g'
}

export STATUSLINE_CACHE_DIR=$(mktemp -d)
TEST_SCRIPT=$(mktemp)
TEST_NATIVE=$(mktemp)

sed 's/^readonly //' "$STATUSLINE" | sed '/^case/,/^esac/d' > "$TEST_SCRIPT"
cp "$NATIVE_MODULE" "$TEST_NATIVE"

assert_contains() {
    local test_name=$1
    local actual=$2
    local expected=$3

    if echo "$actual" | grep -qF "$expected"; then
        PASS=$((PASS + 1))
        echo "  PASS: $test_name"
    else
        FAIL=$((FAIL + 1))
        echo "  FAIL: $test_name"
        echo "    Expected to contain: $expected"
        echo "    Actual: $actual"
    fi
}

assert_not_contains() {
    local test_name=$1
    local actual=$2
    local unexpected=$3

    if echo "$actual" | grep -qF "$unexpected"; then
        FAIL=$((FAIL + 1))
        echo "  FAIL: $test_name"
        echo "    Expected NOT to contain: $unexpected"
        echo "    Actual: $actual"
    else
        PASS=$((PASS + 1))
        echo "  PASS: $test_name"
    fi
}

assert_equals() {
    local test_name=$1
    local actual=$2
    local expected=$3

    if [[ "$actual" == "$expected" ]]; then
        PASS=$((PASS + 1))
        echo "  PASS: $test_name"
    else
        FAIL=$((FAIL + 1))
        echo "  FAIL: $test_name"
        echo "    Expected: $expected"
        echo "    Actual: $actual"
    fi
}

run_func() {
    bash -c "source '$TEST_SCRIPT'; $*"
}

run_native_func() {
    bash -c "source '$TEST_NATIVE'; $*"
}

NOW_EPOCH=$(date -u +%s)
RESET_2H=$(TZ=UTC date -r $((NOW_EPOCH + 7200)) +"%Y-%m-%dT%H:%M:%S" 2>/dev/null)
RESET_6D=$(TZ=UTC date -r $((NOW_EPOCH + 518400)) +"%Y-%m-%dT%H:%M:%S" 2>/dev/null)
RESET_30M=$(TZ=UTC date -r $((NOW_EPOCH + 1800)) +"%Y-%m-%dT%H:%M:%S" 2>/dev/null)
RESET_PAST=$(TZ=UTC date -r $((NOW_EPOCH - 60)) +"%Y-%m-%dT%H:%M:%S" 2>/dev/null)
RESET_4H=$(TZ=UTC date -r $((NOW_EPOCH + 14400)) +"%Y-%m-%dT%H:%M:%S" 2>/dev/null)

RESET_2H_UNIX=$((NOW_EPOCH + 7200))
RESET_6D_UNIX=$((NOW_EPOCH + 518400))

echo "=== statusline.sh tests ==="
echo ""

echo "[Version]"
result=$(bash "$STATUSLINE" --version)
assert_contains "shows version" "$result" "7.0.0"

echo ""
echo "[Help]"
result=$(bash "$STATUSLINE" --help)
assert_contains "help mentions context" "$result" "context"
assert_contains "help mentions model" "$result" "model"
assert_contains "help mentions usage limits" "$result" "limits"
assert_contains "help mentions cost" "$result" "cost"
assert_contains "help mentions duration" "$result" "duration"
assert_not_contains "help no longer mentions Chrome" "$result" "Chrome"
assert_contains "help mentions native rate_limits" "$result" "native"
assert_contains "help mentions effort" "$result" "effort"

echo ""
echo "[parse_used_percentage]"

result=$(run_func "parse_used_percentage '{\"context_window\":{\"used_percentage\":45}}'")
assert_equals "parses integer percentage" "$result" "45"

result=$(run_func "parse_used_percentage '{\"context_window\":{\"used_percentage\":72.5}}'")
assert_equals "truncates decimal" "$result" "72"

result=$(run_func "parse_used_percentage '{\"context_window\":{}}'")
assert_equals "defaults to 0 when missing" "$result" "0"

result=$(run_func "parse_used_percentage '{\"context_window\":{\"used_percentage\":null}}'")
assert_equals "handles null" "$result" "0"

echo ""
echo "[parse_model_name]"

result=$(run_func "parse_model_name '{\"model\":{\"display_name\":\"Opus\"}}'")
assert_equals "parses model name" "$result" "Opus"

result=$(run_func "parse_model_name '{\"model\":{}}'")
assert_equals "defaults to ? when missing" "$result" "?"

echo ""
echo "[parse_effort_level]"

result=$(run_func "parse_effort_level '{\"effort\":{\"level\":\"xhigh\"}}'")
assert_equals "parses effort level" "$result" "xhigh"

result=$(run_func "parse_effort_level '{\"effort\":{}}'")
assert_equals "empty when level missing" "$result" ""

result=$(run_func "parse_effort_level '{\"model\":{\"display_name\":\"Opus\"}}'")
assert_equals "empty when effort missing" "$result" ""

echo ""
echo "[parse_thinking_enabled]"

result=$(run_func "parse_thinking_enabled '{\"thinking\":{\"enabled\":true}}'")
assert_equals "true yields flag" "$result" "1"

result=$(run_func "parse_thinking_enabled '{\"thinking\":{\"enabled\":false}}'")
assert_equals "false yields empty" "$result" ""

result=$(run_func "parse_thinking_enabled '{\"model\":{\"display_name\":\"Opus\"}}'")
assert_equals "empty when thinking missing" "$result" ""

echo ""
echo "[session-scoped effort/thinking cache]"

CACHE_SESSION="test-effort-$$"
rm -f "${STATUSLINE_CACHE_DIR}/effort-${CACHE_SESSION}" "${STATUSLINE_CACHE_DIR}/thinking-${CACHE_SESSION}"

result=$(run_func "parse_effort_level '{\"session_id\":\"$CACHE_SESSION\",\"effort\":{\"level\":\"max\"}}'")
assert_equals "caches effort for session" "$result" "max"

result=$(run_func "parse_effort_level '{\"session_id\":\"$CACHE_SESSION\"}'")
assert_equals "falls back to cached effort" "$result" "max"

result=$(run_func "parse_effort_level '{\"session_id\":\"$CACHE_SESSION\",\"effort\":{\"level\":\"low\"}}'")
assert_equals "effort change overrides cache" "$result" "low"

result=$(run_func "parse_effort_level '{\"session_id\":\"$CACHE_SESSION\"}'")
assert_equals "cache holds newest effort" "$result" "low"

result=$(run_func "parse_effort_level '{\"session_id\":\"other-$$\"}'")
assert_equals "other session unaffected" "$result" ""

result=$(run_func "parse_thinking_enabled '{\"session_id\":\"$CACHE_SESSION\",\"thinking\":{\"enabled\":true}}'")
assert_equals "caches thinking on" "$result" "1"

result=$(run_func "parse_thinking_enabled '{\"session_id\":\"$CACHE_SESSION\"}'")
assert_equals "falls back to cached thinking on" "$result" "1"

result=$(run_func "parse_thinking_enabled '{\"session_id\":\"$CACHE_SESSION\",\"thinking\":{\"enabled\":false}}'")
assert_equals "thinking off overrides cache" "$result" ""

result=$(run_func "parse_thinking_enabled '{\"session_id\":\"$CACHE_SESSION\"}'")
assert_equals "cached thinking off stays off" "$result" ""

rm -f "${STATUSLINE_CACHE_DIR}/effort-${CACHE_SESSION}" "${STATUSLINE_CACHE_DIR}/thinking-${CACHE_SESSION}" "${STATUSLINE_CACHE_DIR}/effort-other-$$" "${STATUSLINE_CACHE_DIR}/thinking-other-$$"

echo ""
echo "[restore effort from transcript]"

TRANSCRIPT_SESSION="test-transcript-$$"
TRANSCRIPT_FILE=$(mktemp)
rm -f "${STATUSLINE_CACHE_DIR}/effort-${TRANSCRIPT_SESSION}" "${STATUSLINE_CACHE_DIR}/thinking-${TRANSCRIPT_SESSION}"

printf '%s\n' \
    '{"type":"assistant","effort":"medium","message":{"content":[{"type":"text"}]}}' \
    '{"type":"assistant","effort":"xhigh","message":{"content":[{"type":"thinking"}]}}' \
    > "$TRANSCRIPT_FILE"

result=$(run_func "read_effort_from_transcript '$TRANSCRIPT_FILE'")
assert_equals "reads newest effort from transcript" "$result" "xhigh"

result=$(run_func "parse_effort_level '{\"session_id\":\"$TRANSCRIPT_SESSION\",\"transcript_path\":\"$TRANSCRIPT_FILE\"}'")
assert_equals "restores effort on resume" "$result" "xhigh"

rm -f "${STATUSLINE_CACHE_DIR}/effort-${TRANSCRIPT_SESSION}"
result=$(run_func "parse_effort_level '{\"session_id\":\"$TRANSCRIPT_SESSION\",\"transcript_path\":\"$TRANSCRIPT_FILE\",\"effort\":{\"level\":\"high\"}}'")
assert_equals "stdin always beats transcript" "$result" "high"

result=$(run_func "parse_effort_level '{\"session_id\":\"$TRANSCRIPT_SESSION\",\"transcript_path\":\"$TRANSCRIPT_FILE\",\"effort\":{\"level\":\"low\"}}'")
assert_equals "stdin change reflected immediately" "$result" "low"

result=$(run_func "parse_effort_level '{\"session_id\":\"$TRANSCRIPT_SESSION\",\"transcript_path\":\"$TRANSCRIPT_FILE\"}'")
assert_equals "cache beats transcript when stdin missing" "$result" "low"

rm -f "${STATUSLINE_CACHE_DIR}/effort-${TRANSCRIPT_SESSION}"
result=$(run_func "parse_effort_level '{\"session_id\":\"$TRANSCRIPT_SESSION\",\"effort\":{\"level\":\"low\"}}'")
assert_equals "stdin used when no transcript" "$result" "low"

THINK_SESSION="test-think-$$"
rm -f "${STATUSLINE_CACHE_DIR}/thinking-${THINK_SESSION}" "${STATUSLINE_CACHE_DIR}/thinking-stdin-${THINK_SESSION}"
result=$(run_func "parse_thinking_enabled '{\"session_id\":\"$THINK_SESSION\",\"transcript_path\":\"$TRANSCRIPT_FILE\",\"thinking\":{\"enabled\":false}}'")
assert_equals "thinking never restored from transcript" "$result" ""

rm -f "${STATUSLINE_CACHE_DIR}/thinking-${THINK_SESSION}" "${STATUSLINE_CACHE_DIR}/thinking-stdin-${THINK_SESSION}"
result=$(run_func "parse_thinking_enabled '{\"session_id\":\"$THINK_SESSION\",\"transcript_path\":\"$TRANSCRIPT_FILE\"}'")
assert_equals "no thinking field yields empty despite transcript" "$result" ""

rm -f "${STATUSLINE_CACHE_DIR}/thinking-${THINK_SESSION}" "${STATUSLINE_CACHE_DIR}/thinking-stdin-${THINK_SESSION}"

result=$(run_func "read_effort_from_transcript '/nonexistent/transcript.jsonl'")
assert_equals "missing transcript yields empty" "$result" ""

rm -f "$TRANSCRIPT_FILE" "${STATUSLINE_CACHE_DIR}/effort-${TRANSCRIPT_SESSION}" "${STATUSLINE_CACHE_DIR}/thinking-${TRANSCRIPT_SESSION}"

echo ""
echo "[get_color_by_effort_level]"

result=$(run_func "get_color_by_effort_level low")
assert_contains "low is gray" "$result" "90m"

result=$(run_func "get_color_by_effort_level medium")
assert_contains "medium is gray" "$result" "90m"

result=$(run_func "get_color_by_effort_level high")
assert_contains "high is cyan" "$result" "36m"

result=$(run_func "get_color_by_effort_level xhigh")
assert_contains "xhigh is yellow" "$result" "33m"

result=$(run_func "get_color_by_effort_level max")
assert_contains "max is yellow" "$result" "33m"

result=$(run_func "get_color_by_effort_level unknown")
assert_contains "unknown level is gray" "$result" "90m"

echo ""
echo "[format_effort_part]"

result=$(run_func "format_effort_part xhigh 1" | strip_colors)
assert_equals "thinking on shows icon and level" "$result" "✻xhigh"

result=$(run_func "format_effort_part xhigh ''" | strip_colors)
assert_equals "thinking off shows level only" "$result" "xhigh"

result=$(run_func "format_effort_part '' 1" | strip_colors)
assert_equals "no level yields empty" "$result" ""

echo ""
echo "[parse_cost]"

result=$(run_func "parse_cost '{\"cost\":{\"total_cost_usd\":3.75}}'")
assert_equals "parses cost" "$result" "3.75"

result=$(run_func "parse_cost '{\"cost\":{}}'")
assert_equals "defaults to 0 when missing" "$result" "0"

echo ""
echo "[parse_duration]"

result=$(run_func "parse_duration '{\"cost\":{\"total_duration_ms\":120000}}'")
assert_equals "parses duration" "$result" "120000"

result=$(run_func "parse_duration '{\"cost\":{}}'")
assert_equals "defaults to 0 when missing" "$result" "0"

echo ""
echo "[format_duration]"

result=$(run_func "format_duration 300000")
assert_equals "5 minutes" "$result" "5m"

result=$(run_func "format_duration 3600000")
assert_equals "1 hour" "$result" "1h 0m"

result=$(run_func "format_duration 5400000")
assert_equals "1.5 hours" "$result" "1h 30m"

result=$(run_func "format_duration 0")
assert_equals "0 minutes" "$result" "0m"

echo ""
echo "[format_cost]"

result=$(run_func "format_cost 0.42")
assert_equals "formats cost" "$result" '$0.42'

result=$(run_func "format_cost 8.7")
assert_equals "pads to 2 decimals" "$result" '$8.70'

result=$(run_func "format_cost 0")
assert_equals "zero cost" "$result" '$0.00'

echo ""
echo "[format_time_remaining]"

result=$(run_func "format_time_remaining 7200")
assert_equals "2 hours" "$result" "2h0m"

result=$(run_func "format_time_remaining 518400")
assert_equals "6 days" "$result" "6d0h"

result=$(run_func "format_time_remaining 1800")
assert_equals "30 minutes" "$result" "30m"

result=$(run_func "format_time_remaining 0")
assert_equals "zero shows now" "$result" "now"

result=$(run_func "format_time_remaining -60")
assert_equals "negative shows now" "$result" "now"

echo ""
echo "[seconds_until_reset]"

result=$(run_func "seconds_until_reset '$RESET_2H'")
# Should be ~7200 but may drift a few seconds during test
(( result >= 7100 && result <= 7200 )) && result_ok="ok" || result_ok="bad: $result"
assert_equals "2h from now ~7200" "$result_ok" "ok"

result=$(run_func "seconds_until_reset '' 2>/dev/null || echo 'error'")
assert_equals "empty returns error" "$result" "error"

# Verify UTC parsing works from non-UTC timezone
utc_future=$(TZ=UTC date -r $((NOW_EPOCH + 3600)) +"%Y-%m-%dT%H:%M:%S" 2>/dev/null)
result=$(TZ=America/New_York run_func "seconds_until_reset '$utc_future'")
(( result >= 3500 && result <= 3600 )) && tz_ok="ok" || tz_ok="bad: $result"
assert_equals "UTC timestamp parsed correctly from non-UTC zone" "$tz_ok" "ok"

echo ""
echo "[timer_icon_for_seconds]"

result=$(run_func "timer_icon_for_seconds 16000 18000")
assert_equals ">75% full circle" "$result" "●"

result=$(run_func "timer_icon_for_seconds 12000 18000")
assert_equals ">50% three-quarter" "$result" "◕"

result=$(run_func "timer_icon_for_seconds 8000 18000")
assert_equals ">25% half" "$result" "◑"

result=$(run_func "timer_icon_for_seconds 3000 18000")
assert_equals ">0% quarter" "$result" "◔"

result=$(run_func "timer_icon_for_seconds 0 18000")
assert_equals "0 empty circle" "$result" "○"

result=$(run_func "timer_icon_for_seconds -100 18000")
assert_equals "negative empty circle" "$result" "○"

echo ""
echo "[get_color_by_percentage]"

result=$(run_func "get_color_by_percentage 30")
assert_contains "30% is green" "$result" "32m"

result=$(run_func "get_color_by_percentage 65")
assert_contains "65% is yellow" "$result" "33m"

result=$(run_func "get_color_by_percentage 85")
assert_contains "85% is yellow" "$result" "33m"

result=$(run_func "get_color_by_percentage 95")
assert_contains "95% is red" "$result" "31m"

result=$(run_func "get_color_by_percentage 59")
assert_contains "59% is green (boundary)" "$result" "32m"

result=$(run_func "get_color_by_percentage 60")
assert_contains "60% is yellow (boundary)" "$result" "33m"

result=$(run_func "get_color_by_percentage 89")
assert_contains "89% is yellow (boundary)" "$result" "33m"

result=$(run_func "get_color_by_percentage 90")
assert_contains "90% is red (boundary)" "$result" "31m"

echo ""
echo "[build_progress_bar]"

bar=$(run_func "build_progress_bar 0 '\033[32m'" | strip_colors)
assert_equals "0% bar is all empty" "$bar" "░░░░░░░░░░░░░░░"

bar=$(run_func "build_progress_bar 100 '\033[31m'" | strip_colors)
assert_equals "100% bar is all filled" "$bar" "███████████████"

bar=$(run_func "build_progress_bar 50 '\033[33m'" | strip_colors)
assert_equals "50% bar is half filled" "$bar" "███████░░░░░░░░"

bar=$(run_func "build_progress_bar 150 '\033[31m'" | strip_colors)
assert_equals "150% clamped to full" "$bar" "███████████████"

bar=$(run_func "build_progress_bar -5 '\033[32m'" | strip_colors)
assert_equals "negative clamped to empty" "$bar" "░░░░░░░░░░░░░░░"

echo ""
echo "[format_output]"

output=$(run_func "format_output 45 Opus 10 30 '$RESET_2H' '$RESET_6D' 1.25 600000" | strip_colors)
assert_contains "contains model name" "$output" "Opus"
assert_contains "contains context percentage" "$output" "45%"
assert_contains "contains 5h limit" "$output" "5h: 10%"
assert_contains "contains week limit" "$output" "Week: 30%"
assert_contains "contains timer icon" "$output" "◑"
assert_contains "contains reset time" "$output" "h"
assert_contains "contains cost" "$output" '$1.25'
assert_contains "contains time" "$output" "Time: 10m"
assert_contains "contains separators" "$output" "│"
assert_not_contains "no model-scoped rows" "$output" "Sonnet:"
assert_not_contains "no fable row" "$output" "Fable:"
assert_not_contains "no warning" "$output" "⚠"

output_effort=$(run_func "format_output 45 Opus 10 30 '$RESET_2H' '$RESET_6D' 1.25 600000 xhigh 1" | strip_colors)
assert_contains "effort follows model name" "$output_effort" "Opus ✻xhigh │"

output_no_thinking=$(run_func "format_output 45 Opus 10 30 '$RESET_2H' '$RESET_6D' 1.25 600000 medium ''" | strip_colors)
assert_contains "effort without thinking icon" "$output_no_thinking" "Opus medium │"

output_no_effort=$(run_func "format_output 45 Opus 10 30 '$RESET_2H' '$RESET_6D' 1.25 600000" | strip_colors)
assert_contains "no effort keeps model followed by separator" "$output_no_effort" "Opus │"

output_no_limits=$(run_func "format_output 45 Opus '' '' '' '' 1.25 600000" | strip_colors)
assert_contains "missing limits show question marks" "$output_no_limits" "5h: ?"

echo ""
echo "[format_usage_part]"

result=$(run_func "format_usage_part '5h' ''" | strip_colors)
assert_contains "missing data shows ?" "$result" "5h: ?"

result=$(run_func "format_usage_part 'Week' '42'" | strip_colors)
assert_contains "present data shows value" "$result" "Week: 42%"

result=$(run_func "format_usage_part '5h' '20' '$RESET_2H' 18000" | strip_colors)
assert_contains "shows timer icon" "$result" "◑"
assert_contains "shows reset time" "$result" "h"

result=$(run_func "format_usage_part '5h' '20' '$RESET_4H' 18000" | strip_colors)
assert_contains "4h shows three-quarter icon" "$result" "◕"

result=$(run_func "format_usage_part '5h' '20' '' 18000" | strip_colors)
assert_contains "no reset without timestamp" "$result" "5h: 20%"

echo ""
echo "=== Native module ==="
echo ""

echo "[unix_to_iso]"

result=$(run_native_func "unix_to_iso $RESET_2H_UNIX")
assert_equals "converts unix to ISO" "$result" "$RESET_2H"

result=$(run_native_func "unix_to_iso '' 2>/dev/null || echo 'error'")
assert_equals "empty returns error" "$result" "error"

result=$(run_native_func "unix_to_iso 'null' 2>/dev/null || echo 'error'")
assert_equals "null returns error" "$result" "error"

result=$(run_native_func "unix_to_iso '0' 2>/dev/null || echo 'error'")
assert_equals "zero returns error" "$result" "error"

echo ""
echo "[get_usage_limits_native]"

native_input="{\"rate_limits\":{\"five_hour\":{\"used_percentage\":25,\"resets_at\":${RESET_2H_UNIX}},\"seven_day\":{\"used_percentage\":50,\"resets_at\":${RESET_6D_UNIX}}}}"
result=$(run_native_func "get_usage_limits_native '$native_input'")
assert_contains "native parses five_hour" "$result" "25|"
assert_contains "native parses seven_day" "$result" "|50|"
assert_contains "native converts five_hour reset" "$result" "$RESET_2H"
assert_contains "native converts seven_day reset" "$result" "$RESET_6D"

# Decimal percentages are truncated
native_decimal="{\"rate_limits\":{\"five_hour\":{\"used_percentage\":33.7,\"resets_at\":${RESET_2H_UNIX}},\"seven_day\":{\"used_percentage\":66.2,\"resets_at\":${RESET_6D_UNIX}}}}"
result=$(run_native_func "get_usage_limits_native '$native_decimal'")
assert_contains "native truncates five_hour decimal" "$result" "33|"
assert_contains "native truncates seven_day decimal" "$result" "|66|"

# Missing rate_limits
result=$(run_native_func "get_usage_limits_native '{\"model\":{\"display_name\":\"Opus\"}}'")
assert_equals "native handles missing rate_limits" "$result" "|||"

# Partial data (only five_hour)
partial_input="{\"rate_limits\":{\"five_hour\":{\"used_percentage\":40,\"resets_at\":${RESET_2H_UNIX}}}}"
result=$(run_native_func "get_usage_limits_native '$partial_input'")
assert_contains "native handles partial data" "$result" "40|"

native_fields=$(run_native_func "get_usage_limits_native '$native_input'" | awk -F'|' '{print NF}')
assert_equals "native emits 4 fields" "$native_fields" "4"


echo ""
echo "=== Integration ==="
echo ""

echo "[Integration — stdin rate_limits]"

full_output=$(echo "{\"context_window\":{\"used_percentage\":55},\"model\":{\"display_name\":\"Sonnet\"},\"effort\":{\"level\":\"high\"},\"thinking\":{\"enabled\":true},\"cost\":{\"total_cost_usd\":2.50,\"total_duration_ms\":900000},\"rate_limits\":{\"five_hour\":{\"used_percentage\":12,\"resets_at\":${RESET_2H_UNIX}},\"seven_day\":{\"used_percentage\":45,\"resets_at\":${RESET_6D_UNIX}}}}" | \
    bash -c "source '$TEST_SCRIPT'; SCRIPT_DIR='$SCRIPT_DIR/scripts'; main" | strip_colors)

assert_contains "has model" "$full_output" "Sonnet"
assert_contains "has effort from stdin" "$full_output" "Sonnet ✻high"
assert_contains "has context" "$full_output" "55%"
assert_contains "has 5h" "$full_output" "5h: 12%"
assert_contains "has timer icon" "$full_output" "◑"
assert_contains "has week" "$full_output" "Week: 45%"
assert_contains "has cost" "$full_output" '$2.50'
assert_contains "has time" "$full_output" "15m"

echo ""
echo "[Integration — no rate_limits on stdin]"

full_output=$(echo '{"context_window":{"used_percentage":55},"model":{"display_name":"Opus"},"cost":{"total_cost_usd":2.50,"total_duration_ms":900000}}' | \
    bash -c "source '$TEST_SCRIPT'; SCRIPT_DIR='$SCRIPT_DIR/scripts'; main" | strip_colors)
assert_contains "missing limits show question marks" "$full_output" "5h: ?"
assert_contains "missing weekly shows question mark" "$full_output" "Week: ?"
assert_not_contains "no warning without a browser source" "$full_output" "⚠"

echo ""
echo "[Project segment]"

SEGMENT_ROOT=$(mktemp -d)
TRUSTED_PROJECT="$SEGMENT_ROOT/trusted/app"
FOREIGN_PROJECT="$SEGMENT_ROOT/foreign/app"
SIBLING_PROJECT="$SEGMENT_ROOT/trusted-sibling/app"
SILENT_PROJECT="$SEGMENT_ROOT/trusted/silent"
for project in "$TRUSTED_PROJECT" "$FOREIGN_PROJECT" "$SIBLING_PROJECT" "$SILENT_PROJECT"; do
    mkdir -p "$project/.claude"
    printf '#!/bin/bash\nprintf "SEGMENT %%s" "$(cat)"\n' > "$project/.claude/statusline-segment.sh"
    chmod +x "$project/.claude/statusline-segment.sh"
done
chmod -x "$SILENT_PROJECT/.claude/statusline-segment.sh"
TRUSTED_FILE="$SEGMENT_ROOT/trusted-roots"
printf '# my projects\n%s/trusted/\n' "$SEGMENT_ROOT" > "$TRUSTED_FILE"

segment_for() {
    local input=$1
    bash -c "source '$TEST_SCRIPT'; TRUSTED_ROOTS_FILE='$TRUSTED_FILE'; print_project_segment '$input'" 2>&1
}

trusted_input="{\"workspace\":{\"project_dir\":\"$TRUSTED_PROJECT\"}}"
assert_equals "trusted project segment gets the same stdin" "$(segment_for "$trusted_input")" "SEGMENT $trusted_input"
cwd_input="{\"cwd\":\"$TRUSTED_PROJECT\"}"
assert_contains "project falls back to cwd" "$(segment_for "$cwd_input")" "SEGMENT"
assert_equals "project outside trusted roots runs nothing" "$(segment_for "{\"workspace\":{\"project_dir\":\"$FOREIGN_PROJECT\"}}")" ""
assert_equals "sibling sharing the root prefix is not trusted" "$(segment_for "{\"workspace\":{\"project_dir\":\"$SIBLING_PROJECT\"}}")" ""
assert_equals "non-executable segment is skipped" "$(segment_for "{\"workspace\":{\"project_dir\":\"$SILENT_PROJECT\"}}")" ""
missing_trusted=$(bash -c "source '$TEST_SCRIPT'; TRUSTED_ROOTS_FILE='$SEGMENT_ROOT/none'; print_project_segment '$trusted_input'" 2>&1)
assert_equals "no trusted roots file runs nothing" "$missing_trusted" ""

rm -rf "$SEGMENT_ROOT"

echo ""
echo "[Color coding]"

low_output=$(run_func "format_output 30 Opus 10 20 '$RESET_2H' '$RESET_6D' 0.5 60000")
assert_contains "low context uses green" "$low_output" "32m"

high_output=$(run_func "format_output 90 Opus 85 95 '$RESET_2H' '$RESET_6D' 5.0 3600000")
assert_contains "high context uses red" "$high_output" "31m"

assert_contains "model uses cyan" "$low_output" "36m"
assert_contains "cost uses yellow" "$low_output" "33m"

mid_usage=$(run_func "format_usage_part '5h' '65'")
assert_contains "65% usage is yellow" "$mid_usage" "33m"

high_usage=$(run_func "format_usage_part 'Week' '92'")
assert_contains "92% usage is red" "$high_usage" "31m"

echo ""
echo "[Test mode]"

test_output=$(bash "$STATUSLINE" --test | strip_colors)
assert_contains "test shows low usage" "$test_output" "45%"
assert_contains "test shows high usage" "$test_output" "85%"
assert_contains "test shows no limits" "$test_output" "?"
assert_contains "test shows model" "$test_output" "Opus"
assert_contains "test shows cost" "$test_output" '$0.42'
assert_contains "test shows time" "$test_output" "Time:"
assert_contains "test shows effort levels" "$test_output" "Opus ✻low"
assert_contains "test shows max effort" "$test_output" "Opus ✻max"
assert_contains "test shows thinking disabled" "$test_output" "Opus medium"

rm -f "$TEST_SCRIPT" "$TEST_NATIVE"

echo ""
echo "========================"
TOTAL=$((PASS + FAIL))
echo "Results: $PASS/$TOTAL passed"
if (( FAIL > 0 )); then
    echo "$FAIL test(s) FAILED"
    exit 1
else
    echo "All tests passed!"
fi
