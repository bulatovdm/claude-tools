#!/usr/bin/env bash
set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/journal-common.sh"

readonly GIT_COMMIT_PATTERN='(^|[;&|(]|[[:space:]])git([[:space:]]+-[cC][[:space:]]+[^[:space:]]+)*[[:space:]]+commit([[:space:]]|$)'

read_command() {
  jq -r '.tool_input.command // ""' 2>/dev/null || true
}

# Тело heredoc — данные, а не команда: файл с текстом «git commit» внутри
# не должен считаться коммитом.
strip_heredocs() {
  awk '
    terminator != "" {
      line = $0
      sub(/^\t+/, "", line)
      if (line == terminator) terminator = ""
      next
    }
    {
      print
      rest = $0
      gsub(/<<</, "", rest)
      if (match(rest, /<<-?[ \t]*["\047]?[A-Za-z_][A-Za-z0-9_]*/)) {
        terminator = substr(rest, RSTART, RLENGTH)
        sub(/^<<-?[ \t]*["\047]?/, "", terminator)
      }
    }
  '
}

is_git_commit() {
  strip_heredocs <<< "$1" | grep -qE "$GIT_COMMIT_PATTERN"
}

has_commits() {
  git -C "$(repository_root)" rev-parse HEAD >/dev/null 2>&1
}

journal_untouched_since_last_commit() {
  local journal=$1
  has_commits || return 1
  git -C "$(repository_root)" ls-files --error-unmatch "$journal" >/dev/null 2>&1 || return 1
  git -C "$(repository_root)" diff --quiet HEAD -- "$journal"
}

refuse() {
  echo "$1" >&2
  exit 2
}

main() {
  local command journal relative
  command=$(read_command)
  is_git_commit "$command" || exit 0
  inside_git_repository || exit 0

  journal=$(journal_path_for_today)
  relative=$(relative_to_repository "$journal")

  if journal_is_unfilled "$journal"; then
    refuse "Коммит заблокирован: журнал сессии $relative не заполнен. Записать цель, что сделано в этом коммите и почему, снять маркер НЕ ЗАПОЛНЕН, затем повторить коммит."
  fi

  if journal_untouched_since_last_commit "$journal"; then
    refuse "Коммит заблокирован: $relative не менялся с прошлого коммита. Каждый коммит сопровождается строкой в журнале — сверить git log за сегодня с журналом и дописать недостающее."
  fi
}

main
