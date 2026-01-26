# Claude Code Tools

Custom tools and scripts for [Claude Code](https://claude.ai/claude-code) CLI.

## Features

### Status Line

Visual progress bar showing context usage and autocompact status:

```
████░░░░░░ 45% │ AC ██░░░░░░░░ 28%
```

- **Left bar** — context used (green → yellow → red)
- **Right bar** — remaining until autocompact triggers

Color thresholds:
- **Green** — safe zone
- **Yellow** — approaching limit
- **Red** — critical

## Requirements

- [Claude Code](https://claude.ai/claude-code) CLI
- `jq` — JSON processor

```bash
brew install jq
```

## Installation

### Quick Install

```bash
git clone https://github.com/YOUR_USERNAME/claude-tools.git
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

## Configuration

### Autocompact Threshold

Set in `~/.claude/settings.json`:

```json
{
  "env": {
    "CLAUDE_AUTOCOMPACT_PCT_OVERRIDE": "80"
  }
}
```

Default: `95` (triggers at 95% - 22% buffer ≈ 73% usage)

## Usage

### Installer Commands

```bash
./install.sh              # Install all tools
./install.sh --force      # Overwrite existing files
./install.sh uninstall    # Remove installed tools
./install.sh status       # Check installation status
./install.sh --help       # Show help
```

### Testing Status Line

```bash
~/.claude/statusline.sh --test
~/.claude/statusline.sh --help
```

## Uninstallation

```bash
./install.sh uninstall
```

## License

MIT
