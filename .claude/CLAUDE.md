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
- Загружает лимиты использования (5h/weekly) с `https://api.anthropic.com/api/oauth/usage`
- OAuth-токен из macOS Keychain: `Claude Code-credentials`
- Лимиты кэшируются в `/tmp/claude-statusline-usage-cache` (обновление раз в 5 мин)
- Цвета: зелёный (<60%), жёлтый (60-80%), красный (80%+)
- При 429 — автоматический рефреш OAuth токена (до 2 попыток), после чего показывается `⚠ refresh failed`
- File lock `/tmp/claude-statusline-usage-lock` защищает от параллельных fetch при нескольких сессиях

## Важно: bash 3.2 на macOS

Claude Code запускает скрипт через `/bin/bash`, который на macOS — bash **3.2** (системный).
`bash` в терминале — bash 5.x (Homebrew). Это разные бинари.

**Не использовать в скрипте:**
- `exec {fd}>file` — динамические fd (только bash 4.1+), использовать `eval "exec 9>file"`

Всегда тестировать через `/bin/bash scripts/statusline.sh`, а не через `bash`.
