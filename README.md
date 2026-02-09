# Claude Token Tracker

A native macOS desktop widget that tracks your lifetime Claude Code token usage in real-time.

Built with SwiftUI. No Xcode required — compiles with just Command Line Tools.

## Features

- **Real-time token counting** — reads live conversation data from Claude Code, updates every few seconds
- **Lifetime totals** with per-model breakdown (Opus, Sonnet, Haiku)
- **Daily budget tracker** with progress bar and configurable alerts
- **macOS notifications** for token milestones (100K, 1M, 10M, etc.)
- **API cost estimate** based on per-model pricing
- **Menu bar integration** with quick stats dropdown
- **Glass UI** — uses macOS vibrancy materials
- **Settings panel** — opacity, always-on-top, launch at login, refresh interval, and more
- **Lightweight** — single Swift file, no dependencies, incremental JSONL parsing

## Requirements

- macOS 14.0 (Sonoma) or later
- Xcode Command Line Tools (`xcode-select --install`)
- [Claude Code](https://claude.ai/download) installed and used at least once

## Install

```bash
git clone https://github.com/JakeDavisGH/ClaudeTokenTracker.git
cd ClaudeTokenTracker
bash install.sh
```

This builds the app and copies it to `/Applications`.

## Build Only

If you just want to build without installing:

```bash
bash build.sh
open build/ClaudeTokenTracker.app
```

## How It Works

Claude Code stores conversation logs as JSONL files in `~/.claude/projects/`. Each assistant message includes a `usage` object with token counts. The widget scans these files incrementally — only reading new bytes from files that have grown — so it's fast and low-overhead even with large conversation histories.

The widget also reads `~/.claude/stats-cache.json` for session metadata (total sessions, message counts, daily activity).

## Settings

Click the gear icon on the widget or use the menu bar to open settings:

- **General** — Launch at login, always on top, show on all spaces
- **Appearance** — Widget opacity, toggle cost/model/session display
- **Budget & Alerts** — Daily token budget, warning threshold, notifications
- **Data** — Refresh interval (2-60s), export CSV, reset data

## Uninstall

```bash
rm -rf /Applications/ClaudeTokenTracker.app
rm -f ~/.claude-token-tracker.json
rm -f ~/Library/LaunchAgents/com.jakedavis.claude-token-tracker.plist
```

## Notes

- On macOS 26 (Tahoe), the build script automatically applies a VFS overlay to work around a duplicate `SwiftBridging` modulemap bug in Command Line Tools.
- The app runs as a menu bar accessory (no Dock icon). Quit from the menu bar icon or Cmd+Q.
- Token counts include input, output, cache read, and cache creation tokens across all models.

## License

MIT
