# Claude Code Tools

Custom tools and scripts for [Claude Code](https://claude.ai/claude-code) CLI.

## Features

### Status Line

Visual status bar showing model, context usage, subscription limits, cost, and session time:

```
Opus 4.6 │ Context: ████░░░░░░░░░░░ 30% │ 5h: 6% 1h34m ◑ │ Week: 35% 6d12h ● │ Sonnet: 0% 6d14h ● │ Cost: $1.25 │ Time: 17m
```

- **Model** — current model name (cyan)
- **Context** — context window usage with progress bar (green → yellow → red)
- **5h** — 5-hour usage window utilization with countdown to reset
- **Week** — 7-day usage window utilization with countdown to reset
- **Sonnet** — weekly Sonnet-specific usage limit with countdown to reset
- **Cost** — session cost in USD
- **Time** — session duration

Timer icons show remaining time until limit reset: ● (>87%) → ◕ (>62%) → ◑ (>37%) → ◔ (>12%) → ○ (reset imminent).

All indicators are color-coded: green (<60%), yellow (60-80%), red (80%+).

### Multi-Session Support

When running multiple Claude Code sessions simultaneously, each session independently tracks its own model and context window size. Model and context window are frozen at session start via a `SessionStart` hook — changes to the global model setting in other sessions don't affect the status line of existing sessions.

### How It Works

Usage limits are fetched from **claude.ai via Chrome AppleScript** — the script executes an XHR request directly in an open claude.ai browser tab, bypassing Cloudflare and OAuth token issues. Data is cached for 5 minutes.

If no claude.ai tab is found, one is automatically opened. Error states are shown in the status bar:

| Status | Meaning |
|--------|---------|
| `⚠ open Chrome` | Chrome is not running |
| `⚠ open claude.ai` | No claude.ai tab found (auto-opens one) |
| `⚠ enable Chrome JS` | "Allow JavaScript from Apple Events" is disabled |
| `⚠ API error` | claude.ai API returned an error |

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
2. Configure `settings.json`
3. Open Chrome with claude.ai if needed
4. Check that "Allow JavaScript from Apple Events" is enabled

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
```

## Uninstallation

```bash
./install.sh uninstall
```

## License

MIT
