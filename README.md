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

Timer icons show remaining time until limit reset: ● (full) → ◕ → ◑ → ◔ → ○ (empty, reset imminent).

All indicators are color-coded: green (<60%), yellow (60-80%), red (80%+).

Usage limits are fetched from Anthropic API every 60 seconds and cached locally.

### Authentication

The status line uses the OAuth token from macOS Keychain (stored by Claude Code automatically). No additional setup required for Pro/Max subscribers.

## Requirements

- [Claude Code](https://claude.ai/claude-code) CLI
- `jq` — JSON processor
- macOS (uses `security` command for Keychain access)

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
