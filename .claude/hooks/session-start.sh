#!/usr/bin/env bash
set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/journal-common.sh"

readonly PREVIOUS_JOURNALS_SHOWN=3

create_journal_if_missing() {
  local path=$1
  [ -f "$path" ] && return 0
  mkdir -p "$(dirname "$path")"
  cat > "$path" <<TEMPLATE
# $(basename "$path" .md)

$JOURNAL_TEMPLATE_MARKER
<!-- Удалить строку выше при первой записи. Пока она на месте, харнес считает журнал пустым и блокирует коммит и завершение сессии. -->

**Цель.**

**Состояние на входе.**

## Ход

## Итог

**Точка входа для следующей сессии.**
TEMPLATE
}

print_journal_pointer() {
  local path=$1
  echo "ЖУРНАЛ ЭТОЙ СЕССИИ: $(relative_to_repository "$path")"
  if journal_is_unfilled "$path"; then
    echo "Статус: создан харнесом, ещё не заполнен. Записывать по ходу работы, а не в конце."
  else
    echo "Статус: уже заполняется (работа за сегодня продолжается) — дописывать, не переписывать."
  fi
}

print_previous_journals() {
  local current=$1 previous file
  previous=$(find "$(journal_directory)" -maxdepth 1 -name '*.md' 2>/dev/null | grep -vxF "$current" | sort | tail -"$PREVIOUS_JOURNALS_SHOWN" || true)
  [ -z "$previous" ] && return 0
  echo
  echo "ПРЕДЫДУЩИЕ ЖУРНАЛЫ (прочитать перед работой, особенно «Точку входа»):"
  while read -r file; do
    echo "  $(relative_to_repository "$file")"
  done <<< "$previous"
}

print_protocol_reminder() {
  cat <<'REMINDER'

ПРОТОКОЛ ЖУРНАЛА (проверяется хуками, не памятью):
  - Каждый значимый шаг, решение или отвергнутый вариант -> строка в «Ход» сразу, а не в конце.
  - Коммит блокируется, если журнал за сегодня пуст или не менялся с прошлого коммита.
  - Журнал и git commit — разными командами: гвард смотрит журнал до запуска команды.
  - Завершение хода с незакоммиченной работой и пустым журналом блокируется (один раз за сессию).
REMINDER
}

main() {
  local journal
  journal=$(journal_path_for_today)
  create_journal_if_missing "$journal"
  print_journal_pointer "$journal"
  print_previous_journals "$journal"
  print_protocol_reminder
}

main
