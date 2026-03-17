# Claude Code Tools

## Структура проекта

```
scripts/statusline.sh    - Скрипт статус-линии для Claude Code
tests/statusline_test.sh - Тесты статус-линии
install.sh               - Скрипт установки
```

## Правила работы

- При добавлении новых фич или изменении функциональности — обновлять README.md

## Стиль кода

- Самодокументирующийся код: говорящие имена функций и переменных вместо комментариев
- Комментарии только когда логика действительно неочевидна
- Bash-скрипты используют `set -euo pipefail`
- Константы через `readonly` в начале файла

## Тестирование

```bash
bash tests/statusline_test.sh
```

Тесты должны проходить перед коммитом. Тестовый файл подключает основной скрипт через `source` со снятым `readonly` для возможности мокирования переменных.

## Архитектура статус-линии

- Получает JSON от Claude Code через stdin (model, context_window, cost и т.д.)
- Загружает лимиты использования (5h/weekly) через **Chrome AppleScript** — XHR в контексте открытой вкладки claude.ai
- Endpoint: `GET /api/organizations/{orgId}/usage` на claude.ai
- Лимиты кэшируются в `/tmp/claude-statusline-usage-cache` (обновление раз в 5 мин, stale через 10 мин)
- Цвета: зелёный (<60%), жёлтый (60-80%), красный (80%+)
- При ошибках показывает причину: `⚠ open Chrome`, `⚠ open claude.ai`, `⚠ enable Chrome JS`
- Если вкладка claude.ai не найдена — автоматически открывает
- File lock `/tmp/claude-statusline-usage-lock` защищает от параллельных fetch при нескольких сессиях
- Требует: Chrome → View → Developer → Allow JavaScript from Apple Events

## Важно: bash 3.2 на macOS

Claude Code запускает скрипт через `/bin/bash`, который на macOS — bash **3.2** (системный).
`bash` в терминале — bash 5.x (Homebrew). Это разные бинари.

**Не использовать в скрипте:**
- `exec {fd}>file` — динамические fd (только bash 4.1+), использовать `eval "exec 9>file"`
- `flock` — нет на macOS, использовать `mkdir` как атомарный лок

Всегда тестировать через `/bin/bash scripts/statusline.sh`, а не через `bash`.
