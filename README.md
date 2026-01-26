# Claude Code Tools

Custom tools and scripts for [Claude Code](https://claude.ai/claude-code) CLI.

## Features

### Status Line

Visual progress bar showing context usage and autocompact warning:

```
Context: ████░░░░░░ 45%
```

When approaching autocompact (≤10% remaining):

```
Context: ███████░░░ 70% │ AC: ░░░░░░░░░░ 7%
```

- **Context** — usage percentage (green → yellow → red)
- **AC** — remaining until autocompact triggers (appears at ≤10%)

Autocompact triggers at 77% usage (22.5% buffer reserved).

## Requirements

- [Claude Code](https://claude.ai/claude-code) CLI
- `jq` — JSON processor

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
