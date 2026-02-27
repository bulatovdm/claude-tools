#!/bin/bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
STATUSLINE="$SCRIPT_DIR/scripts/statusline.sh"

PASS=0
FAIL=0

strip_colors() {
    sed 's/\x1b\[[0-9;]*m//g'
}

TEST_SCRIPT=$(mktemp)
sed 's/^readonly //' "$STATUSLINE" | sed '/^case/,/^esac/d' > "$TEST_SCRIPT"

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

run_func_with_cache() {
    local cache_file=$1
    shift
    bash -c "source '$TEST_SCRIPT'; USAGE_CACHE_FILE='$cache_file'; $*"
}

echo "=== statusline.sh tests ==="
echo ""

echo "[Version]"
result=$(bash "$STATUSLINE" --version)
assert_contains "shows version" "$result" "3.2.0"

echo ""
echo "[Help]"
result=$(bash "$STATUSLINE" --help)
assert_contains "help mentions context" "$result" "context"
assert_contains "help mentions model" "$result" "model"
assert_contains "help mentions usage limits" "$result" "limits"
assert_contains "help mentions cost" "$result" "cost"
assert_contains "help mentions duration" "$result" "duration"

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

result=$(run_func "format_duration 45000")
assert_equals "less than 1 minute" "$result" "0m"

echo ""
echo "[format_cost]"

result=$(run_func "format_cost 0.42")
assert_equals "formats cost" "$result" '$0.42'

result=$(run_func "format_cost 8.7")
assert_equals "pads to 2 decimals" "$result" '$8.70'

result=$(run_func "format_cost 0")
assert_equals "zero cost" "$result" '$0.00'

echo ""
echo "[get_color_by_percentage]"

result=$(run_func "get_color_by_percentage 30")
assert_contains "30% is green" "$result" "32m"

result=$(run_func "get_color_by_percentage 65")
assert_contains "65% is yellow" "$result" "33m"

result=$(run_func "get_color_by_percentage 85")
assert_contains "85% is red" "$result" "31m"

result=$(run_func "get_color_by_percentage 59")
assert_contains "59% is green (boundary)" "$result" "32m"

result=$(run_func "get_color_by_percentage 60")
assert_contains "60% is yellow (boundary)" "$result" "33m"

result=$(run_func "get_color_by_percentage 79")
assert_contains "79% is yellow (boundary)" "$result" "33m"

result=$(run_func "get_color_by_percentage 80")
assert_contains "80% is red (boundary)" "$result" "31m"

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

output=$(run_func "format_output 45 Opus 10 30 5 1.25 600000" | strip_colors)
assert_contains "contains model name" "$output" "Opus"
assert_contains "contains context percentage" "$output" "45%"
assert_contains "contains 5h limit" "$output" "5h: 10%"
assert_contains "contains week limit" "$output" "Week: 30%"
assert_contains "contains sonnet limit" "$output" "Sonnet: 5%"
assert_contains "contains cost" "$output" '$1.25'
assert_contains "contains time" "$output" "Time: 10m"
assert_contains "contains separators" "$output" "│"

echo ""
echo "[format_usage_part]"

result=$(run_func "format_usage_part '5h' ''" | strip_colors)
assert_contains "missing data shows ?" "$result" "5h: ?"

result=$(run_func "format_usage_part 'Week' '42'" | strip_colors)
assert_contains "present data shows value" "$result" "Week: 42%"

echo ""
echo "[usage_cache_is_stale]"

STALE_CACHE="/tmp/claude-statusline-test-stale-$$"
rm -f "$STALE_CACHE"

result=$(run_func_with_cache "$STALE_CACHE" "USAGE_CACHE_MAX_AGE=60; if usage_cache_is_stale; then echo stale; else echo fresh; fi")
assert_equals "missing cache is stale" "$result" "stale"

echo '{"five_hour":{"utilization":5.0},"seven_day":{"utilization":20.0}}' > "$STALE_CACHE"
result=$(run_func_with_cache "$STALE_CACHE" "USAGE_CACHE_MAX_AGE=60; if usage_cache_is_stale; then echo stale; else echo fresh; fi")
assert_equals "recent cache is fresh" "$result" "fresh"

touch -t 202001010000 "$STALE_CACHE"
result=$(run_func_with_cache "$STALE_CACHE" "USAGE_CACHE_MAX_AGE=60; if usage_cache_is_stale; then echo stale; else echo fresh; fi")
assert_equals "old cache is stale" "$result" "stale"

rm -f "$STALE_CACHE"

echo ""
echo "[get_usage_limits from cache]"

READ_CACHE="/tmp/claude-statusline-test-read-$$"
echo '{"five_hour":{"utilization":25.0},"seven_day":{"utilization":50.0},"seven_day_sonnet":{"utilization":10.0}}' > "$READ_CACHE"

result=$(run_func_with_cache "$READ_CACHE" "USAGE_CACHE_MAX_AGE=9999; get_usage_limits")
assert_equals "reads limits from cache" "$result" "25|50|10"

rm -f "$READ_CACHE"

EMPTY_CACHE="/tmp/claude-statusline-test-empty-$$"
rm -f "$EMPTY_CACHE"
result=$(bash -c "
    source '$TEST_SCRIPT'
    USAGE_CACHE_FILE='$EMPTY_CACHE'
    fetch_usage_limits() { return 1; }
    get_usage_limits
")
assert_equals "no cache returns empty" "$result" "||"

echo ""
echo "[Integration]"

INT_CACHE="/tmp/claude-statusline-test-int-$$"
echo '{"five_hour":{"utilization":12.0},"seven_day":{"utilization":45.0},"seven_day_sonnet":{"utilization":8.0}}' > "$INT_CACHE"

full_output=$(echo '{"context_window":{"used_percentage":55},"model":{"display_name":"Sonnet"},"cost":{"total_cost_usd":2.50,"total_duration_ms":900000}}' | \
    bash -c "
        source '$TEST_SCRIPT'
        USAGE_CACHE_FILE='$INT_CACHE'
        USAGE_CACHE_MAX_AGE=9999
        main
    " | strip_colors)

assert_contains "has model" "$full_output" "Sonnet"
assert_contains "has context" "$full_output" "55%"
assert_contains "has 5h" "$full_output" "5h: 12%"
assert_contains "has week" "$full_output" "Week: 45%"
assert_contains "has sonnet" "$full_output" "Sonnet: 8%"
assert_contains "has cost" "$full_output" '$2.50'
assert_contains "has time" "$full_output" "15m"

rm -f "$INT_CACHE"

echo ""
echo "[Color coding]"

low_output=$(run_func "format_output 30 Opus 10 20 5 0.5 60000")
assert_contains "low context uses green" "$low_output" "32m"

high_output=$(run_func "format_output 90 Opus 85 95 70 5.0 3600000")
assert_contains "high context uses red" "$high_output" "31m"

assert_contains "model uses cyan" "$low_output" "36m"
assert_contains "cost uses yellow" "$low_output" "33m"

mid_usage=$(run_func "format_usage_part '5h' '65'")
assert_contains "65% usage is yellow" "$mid_usage" "33m"

high_usage=$(run_func "format_usage_part 'Week' '82'")
assert_contains "82% usage is red" "$high_usage" "31m"

echo ""
echo "[Test mode]"

test_output=$(bash "$STATUSLINE" --test | strip_colors)
assert_contains "test shows low usage" "$test_output" "45%"
assert_contains "test shows high usage" "$test_output" "85%"
assert_contains "test shows no limits" "$test_output" "?"
assert_contains "test shows model" "$test_output" "Opus"
assert_contains "test shows sonnet" "$test_output" "Sonnet:"
assert_contains "test shows cost" "$test_output" '$0.42'
assert_contains "test shows time" "$test_output" "Time:"

rm -f "$TEST_SCRIPT"

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
