# Claude Code Tools

## Структура проекта

```
scripts/statusline.sh        - Скрипт статус-линии для Claude Code
scripts/session.sh           - Интерактивный пикер сессий (alias: cs)
scripts/git-hooks/           - Глобальные git-хуки (чистка подписей Claude): commit-msg + post-commit
scripts/link-global-hooks.sh - Делегаторы к глобальным хукам для проектов с локальным core.hooksPath
tests/statusline_test.sh     - Тесты статус-линии
install.sh                   - Скрипт установки
```

## Правила работы

- При добавлении новых фич или изменении функциональности — обновлять README.md

## Стиль кода

- Самодокументирующийся код: говорящие имена функций и переменных вместо комментариев
- Комментарии только когда логика действительно неочевидна
- Bash-скрипты используют `set -euo pipefail`
- Константы через `readonly` в начале файла

## Тестирование и деплой

```bash
bash tests/statusline_test.sh
```

Тесты должны проходить перед коммитом. Тестовый файл подключает основной скрипт через `source` со снятым `readonly` для возможности мокирования переменных.

**После любых изменений скрипта — обязательно деплоить:**

```bash
cp scripts/statusline.sh ~/.claude/statusline.sh
```

Claude Code использует `~/.claude/statusline.sh`, а не файл из репозитория.

## Архитектура статус-линии

- Получает JSON от Claude Code через stdin (model, context_window, cost и т.д.)
- Лимиты 5h/weekly берёт из `rate_limits` в stdin (`usage_native.sh`) — не зависит от браузера
- Model-scoped лимиты (Sonnet, Fable) есть только в API claude.ai: `GET /api/organizations/{orgId}/usage`
  через **Chrome AppleScript** — XHR в контексте открытой вкладки (`usage_chrome.sh`)
- В Chrome не ходит вовсе, если `STATUSLINE_SHOW_SONNET` и `STATUSLINE_SHOW_FABLE` выключены
- Chrome-лимиты кэшируются в `/tmp/claude-statusline-usage-cache` (обновление раз в 5 мин, stale через 10 мин,
  затем ещё 30 мин показываются последние значения)
- Второй инстанс Chrome (headless-рендер из того же `Google Chrome.app`) перехватывает Apple Events:
  скрипт это распознаёт (0 окон + >1 процесса) и не трогает вкладки
- Цвета: зелёный (<60%), жёлтый (60-90%), красный (90%+)
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
