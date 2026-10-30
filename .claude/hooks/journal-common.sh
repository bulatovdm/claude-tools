#!/usr/bin/env bash
# Общие функции журнала сессий. Подключается хуками через source.

readonly JOURNAL_TEMPLATE_MARKER='<!-- НЕ ЗАПОЛНЕН -->'
readonly JOURNAL_RELATIVE_DIR="knowledge/journal"

repository_root() {
  if [ -n "${JOURNAL_REPOSITORY_ROOT:-}" ]; then
    echo "$JOURNAL_REPOSITORY_ROOT"
  else
    cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd
  fi
}

journal_directory() {
  echo "$(repository_root)/$JOURNAL_RELATIVE_DIR"
}

journal_path_for_today() {
  local today existing
  today=$(date +%F)
  existing=$(find "$(journal_directory)" -maxdepth 1 -name "$today-*.md" 2>/dev/null | sort | tail -1)
  if [ -n "$existing" ]; then
    echo "$existing"
  else
    echo "$(journal_directory)/$today-01.md"
  fi
}

relative_to_repository() {
  echo "${1#$(repository_root)/}"
}

journal_is_unfilled() {
  local path=$1
  [ ! -f "$path" ] && return 0
  grep -qF "$JOURNAL_TEMPLATE_MARKER" "$path"
}

inside_git_repository() {
  git -C "$(repository_root)" rev-parse --is-inside-work-tree >/dev/null 2>&1
}

has_uncommitted_work_outside_journal() {
  git -C "$(repository_root)" status --porcelain 2>/dev/null | grep -v "$JOURNAL_RELATIVE_DIR/" | grep -q .
}
