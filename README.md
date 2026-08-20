# Claude Code Tools

Custom tools and scripts for [Claude Code](https://claude.ai/claude-code) CLI.

## Features

### Status Line

Visual status bar showing model, thinking effort, context usage, subscription limits, cost, and session time:

```
Opus 4.6 ✻xhigh │ Context: ████░░░░░░░░░░░ 30% │ 5h: 6% 1h34m ◑ │ Week: 35% 6d12h ● │ Cost: $1.25 │ Time: 17m
```

- **Model** — current model name (cyan)
- **Effort** — thinking effort level (`low`, `medium`, `high`, `xhigh`, `max`), prefixed with ✻ while thinking is enabled
- **Context** — context window usage with progress bar (green → yellow → red)
- **5h** — 5-hour usage window utilization with countdown to reset
- **Week** — 7-day usage window utilization with countdown to reset
- **Sonnet** — weekly Sonnet-specific usage limit (hidden by default; see [Configuration](#configuration))
- **Fable** — weekly Fable-specific usage limit (hidden by default; see [Configuration](#configuration))
- **Cost** — session cost in USD
- **Time** — session duration

Timer icons show remaining time until limit reset: ● (>87%) → ◕ (>62%) → ◑ (>37%) → ◔ (>12%) → ○ (reset imminent).

All indicators are color-coded: green (<60%), yellow (60-90%), red (90%+). The effort level has its own scale: `low`/`medium` gray, `high` cyan, `xhigh`/`max` yellow.

Effort and thinking state come from the statusline stdin JSON (`.effort.level` and `.thinking.enabled`). Both are re-read on every render, so switching effort mid-session updates the indicator immediately. Unlike model and context window, they are not frozen at session start.

Each observed value is cached per session in `~/.claude/statusline-cache/` (`effort-${session_id}`, `thinking-${session_id}`; durable across reboots, pruned by `cs` after 30 days of inactivity). When a render arrives without these fields, the last value seen *in that same session* is shown instead — so the indicator never falls back to a level left over from a different session. A `false` value for `.thinking.enabled` is cached as an explicit "off" and is not confused with a missing field.

**Effort leaks between sessions.** Claude Code stores `effortLevel` and `alwaysThinkingEnabled` globally in `~/.claude/settings.json`; switching effort with `/effort` writes there immediately (except `max`, which is session-only). Running sessions hold their level in memory and are unaffected — the leak hits **new and resumed launches**, which read whatever the last session left behind. Claude Code does not restore a session's own effort on `--resume`, and per-session persistence is not supported natively.

The fix lives in the launchers, using the session-scoped `--effort` flag (which never touches the global file):

- **Resume**: the session picker (`cs`) reads the session's actual level from its transcript (`~/.claude/projects/*/${session_id}.jsonl` records `"effort"` on every assistant entry) and launches `claude --effort <level> --resume <id>`.
- **New sessions**: the `cn` alias launches `claude --effort high`, so a fresh session always starts at a known level regardless of what other sessions wrote to the global settings.

Thinking has no launch flag or environment variable, so its only handle is the global `alwaysThinkingEnabled`: `cs` restores it from the statusline's `~/.claude/statusline-cache/thinking-${session_id}` cache (transcripts record nothing about thinking, so this cache is the only per-session record of it; sessions that never rendered the statusline have nothing to restore from).

The statusline simply trusts stdin, which reports what Claude Code will actually use. The transcript remains a display fallback only for Claude Code versions that don't send the effort field at all. Sessions launched bare (`claude`, `claude --resume`, `claude -c`) keep the global values — the indicator still tells the truth about what will run, it just isn't the session's historical level.

### Configuration

| Variable | Default | Description |
|----------|---------|-------------|
| `STATUSLINE_SHOW_SONNET` | `0` | Show the weekly Sonnet-specific limit. Set to `1` to display it. Currently the API reports no Sonnet-scoped limit, so this shows `Sonnet: ?`. |
| `STATUSLINE_SHOW_FABLE` | `0` | Show the weekly Fable-specific limit. Set to `1` to display it. Fable replaced Sonnet as the model-scoped weekly limit reported by the API. |

Model-scoped weekly limits are read from the `limits[]` array in the claude.ai usage response, matched by `scope.model.display_name`. The legacy top-level `seven_day_<model>` keys are still used as a fallback when present.

### Multi-Session Support

When running multiple Claude Code sessions simultaneously, each session independently tracks its own model and context window size. Model and context window are frozen at session start via a `SessionStart` hook — changes to the global model setting in other sessions don't affect the status line of existing sessions.

### How It Works

Usage limits are fetched from **claude.ai via Chrome AppleScript** — the script executes an XHR request directly in an open claude.ai browser tab, bypassing Cloudflare and OAuth token issues. Data is cached for 5 minutes. This provides the most complete data including model-scoped weekly limits.

> **Note:** Claude Code v2.1.80+ provides `rate_limits` in the statusline stdin JSON natively, but currently without model-scoped limits. A native usage module (`usage_native.sh`) is included for future use when the native API becomes more complete.

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

Before launching, reads the session's own effort level from its transcript and passes it via `claude --effort` (session-scoped, the global settings stay untouched); thinking state is restored into `~/.claude/settings.json` as best-effort. See [Effort leaks between sessions](#status-line) above. For new sessions, the `cn` alias (`claude --effort high`) gives every fresh start a known level.

If `fzf` is installed, uses fuzzy finder for selection. Otherwise falls back to a numbered list.

### Git Hooks

Global git hooks that clean up auto-generated Claude Code signatures from commit messages:

- Removes `Co-Authored-By: ... <noreply@anthropic.com>` (case-insensitive)
- Removes `🤖 Generated with [Claude Code]`
- Strips trailing blank lines

Two hooks work together so the signature is stripped regardless of how the commit was made:

- **`commit-msg`** cleans the message before the commit is written. Covers plain commits and merges — but `git commit --no-verify` bypasses it entirely (by git design).
- **`post-commit`** cleans the message *after* the commit by amending in place. It runs even with `--no-verify`, so it closes that gap for plain commits and conflict-resolved merge commits. It is re-entry guarded and skips mid-operation states (rebase/cherry-pick).

The one path neither fully covers is a **clean (conflict-free) merge made with `git merge --no-verify`**: git skips `post-commit` for auto-created merge commits, and amending is impossible while `MERGE_HEAD` is set. A normal `git merge` (without `--no-verify`) is still cleaned by `commit-msg`.

If the project has its own `commit-msg` hook in `.git/hooks/`, it will be called after cleanup — so local project hooks (conventional commits validation, etc.) still work.

> **Note:** Projects that override `core.hooksPath` locally (e.g. `core.hooksPath = .githooks`) bypass global hooks entirely — git honours only one hooksPath. Run `scripts/link-global-hooks.sh [PROJECT_DIR]` inside such a project to wire its local hooks dir to the global ones: it installs thin `commit-msg` / `post-commit` delegators that call the global hook and then any pre-existing project hook (which is preserved as `.<hook>.project`). So Claude signatures get cleaned while the project's own logic (conventional-commits validation, composer checks, …) keeps running. Re-running the script is idempotent.

### Malformed Tool-Call Hook

A `Stop` hook that catches malformed tool calls left as raw text in the model's last message (an unparsed tool-invocation block that never became a real tool_use). When detected, it blocks the stop so the model retries the call cleanly instead of halting and waiting for the user.

Detection anchors on an opening signature tag (`<invoke name=` or `<parameter name=`) at the start of a line — the way a real tool call serializes. Fenced code blocks and inline code are stripped first, so a tag quoted as an example (in ``` or backticks) does not count. Prose that merely mentions the tags mid-sentence (e.g. while editing this hook) no longer triggers a false block.

If the retry is also malformed, the hook keeps nudging — up to 3 attempts per session (tracked in `~/.claude/.malformed-toolcall-attempts/`), then gives up to the user to avoid an infinite loop. A clean turn resets the counter. (Earlier versions bailed out on the very first repeat via the `stop_hook_active` reentrancy guard, which is why the model could still hang after a single failed retry.)

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
