#!/usr/bin/env bash
set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/journal-common.sh"

already_warned_marker() {
  echo "${TMPDIR:-/tmp}/claude-tools-journal-guard-$1"
}

main() {
  local input session marker journal
  input=$(cat)
  [ "$(jq -r '.stop_hook_active // false' <<< "$input" 2>/dev/null)" = "true" ] && exit 0
  session=$(jq -r '.session_id // "unknown"' <<< "$input" 2>/dev/null || echo unknown)
  marker=$(already_warned_marker "$session")
  [ -f "$marker" ] && exit 0

  inside_git_repository || exit 0
  journal=$(journal_path_for_today)
  journal_is_unfilled "$journal" || exit 0
  has_uncommitted_work_outside_journal || exit 0

  touch "$marker"
  echo "Сессия не закрыта: в работе есть изменения, а журнал $(relative_to_repository "$journal") пуст. Записать цель, ход, итог и точку входа для следующей сессии, снять маркер НЕ ЗАПОЛНЕН." >&2
  exit 2
}

main
