# Claude Code Tools

Custom tools and scripts for [Claude Code](https://claude.ai/claude-code) CLI.

## Features

### Status Line

Visual status bar showing model, context usage, subscription limits, cost, and session time:

```
Opus 4.6 │ Context: ████░░░░░░░░░░░ 30% │ 5h: 6% 1h34m ◑ │ Week: 35% 6d12h ● │ Cost: $1.25 │ Time: 17m
```

- **Model** — current model name (cyan)
- **Context** — context window usage with progress bar (green → yellow → red)
- **5h** — 5-hour usage window utilization with countdown to reset
- **Week** — 7-day usage window utilization with countdown to reset
- **Sonnet** — weekly Sonnet-specific usage limit (hidden by default; see [Configuration](#configuration))
- **Cost** — session cost in USD
- **Time** — session duration

Timer icons show remaining time until limit reset: ● (>87%) → ◕ (>62%) → ◑ (>37%) → ◔ (>12%) → ○ (reset imminent).

All indicators are color-coded: green (<60%), yellow (60-80%), red (80%+).

### Configuration

| Variable | Default | Description |
|----------|---------|-------------|
| `STATUSLINE_SHOW_SONNET` | `0` | Show the weekly Sonnet-specific limit. Hidden by default since this separate limit was removed; set to `1` to display it. |

### Multi-Session Support

When running multiple Claude Code sessions simultaneously, each session independently tracks its own model and context window size. Model and context window are frozen at session start via a `SessionStart` hook — changes to the global model setting in other sessions don't affect the status line of existing sessions.

### How It Works

Usage limits are fetched from **claude.ai via Chrome AppleScript** — the script executes an XHR request directly in an open claude.ai browser tab, bypassing Cloudflare and OAuth token issues. Data is cached for 5 minutes. This provides the most complete data including Sonnet-specific weekly limits.

> **Note:** Claude Code v2.1.80+ provides `rate_limits` in the statusline stdin JSON natively, but currently without Sonnet-specific limits. A native usage module (`usage_native.sh`) is included for future use when the native API becomes more complete.

If no claude.ai tab is found, one is automatically opened. Error states are shown in the status bar:

| Status | Meaning |
|--------|---------|
| `⚠ open Chrome` | Chrome is not running |
| `⚠ open claude.ai` | No claude.ai tab found (auto-opens one) |
| `⚠ enable Chrome JS` | "Allow JavaScript from Apple Events" is disabled |
| `⚠ API error` | claude.ai API returned an error |

### Session Picker

Interactive session picker for Claude Code — workaround for limited `/resume` functionality:

```bash
cs                    # sessions for current directory
cs --all              # all sessions across projects
cs --all -n 50        # show up to 50 sessions
cs --list             # non-interactive list (no picker)
cs -p /path/to/repo   # sessions for a specific project
```

Reads `~/.claude/history.jsonl`, groups prompts by session, shows date/duration/message count/preview. Select a session by number → launches `claude --resume <session-id>`.

If `fzf` is installed, uses fuzzy finder for selection. Otherwise falls back to a numbered list.

### Git Hooks

Global git hooks that clean up auto-generated Claude Code signatures from commit messages:

- Removes `Co-Authored-By: ... <noreply@anthropic.com>`
- Removes `🤖 Generated with [Claude Code]`
- Strips trailing blank lines

If the project has its own `commit-msg` hook in `.git/hooks/`, it will be called after cleanup — so local project hooks (conventional commits validation, etc.) still work.

> **Note:** Projects that override `core.hooksPath` locally (e.g. `core.hooksPath = .githooks`) bypass global hooks entirely. For those projects, add Claude signature cleanup to the project's own `commit-msg` hook.

### Malformed Tool-Call Hook

A `Stop` hook that catches malformed tool calls left as raw text in the model's last message (an unparsed tool-invocation block that never became a real tool_use). When detected, it blocks the stop so the model retries the call cleanly instead of halting and waiting for the user.

Enabled and disabled independently of the main installer:

```bash
scripts/hooks/malformed-toolcall-hook.sh enable    # install + register in settings.json
scripts/hooks/malformed-toolcall-hook.sh disable   # remove from settings.json
scripts/hooks/malformed-toolcall-hook.sh status    # show current state
```

A kill-switch flag disables the hook globally without changing `settings.json`:

```bash
touch ~/.claude/.disable-malformed-toolcall-hook    # off
rm ~/.claude/.disable-malformed-toolcall-hook       # on
```

Changes take effect from the next Claude Code session (or after opening `/hooks`).

## Requirements

- [Claude Code](https://claude.ai/claude-code) CLI
- `jq` — JSON processor
- macOS with Google Chrome
- **Chrome setting**: View → Developer → Allow JavaScript from Apple Events

```bash
brew install jq
```

## Installation

### Quick Install

```bash
git clone https://github.com/bulatovdm/claude-tools.git
cd claude-tools
./install.sh
```

The installer will:
1. Install the status line script to `~/.claude/`
2. Install git hooks to `~/.git-hooks/` and set global `core.hooksPath`
3. Configure `settings.json`
4. Open Chrome with claude.ai if needed
5. Check that "Allow JavaScript from Apple Events" is enabled

### Manual Install

```bash
cp scripts/statusline.sh ~/.claude/statusline.sh
chmod +x ~/.claude/statusline.sh
```

Add to `~/.claude/settings.json`:

```json
{
  "statusLine": {
    "type": "command",
    "command": "~/.claude/statusline.sh"
  }
}
```

Then enable in Chrome: **View → Developer → Allow JavaScript from Apple Events**

## Usage

### Installer Commands

```bash
./install.sh              # Install all tools
./install.sh --force      # Overwrite existing files
./install.sh uninstall    # Remove installed tools
./install.sh status       # Check installation status
./install.sh --help       # Show help
```

### Testing

```bash
bash tests/statusline_test.sh    # Run tests
~/.claude/statusline.sh --test   # Visual preview
~/.claude/statusline.sh --help   # Show help
~/.claude/session.sh --help      # Session picker help
```

## Uninstallation

```bash
./install.sh uninstall
```

## License

MIT
