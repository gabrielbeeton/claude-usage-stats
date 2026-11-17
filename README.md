# Usage Stats

A small floating macOS window that shows your Claude Code token usage: a
GitHub-style calendar of daily usage, totals, and a per-model breakdown.

It reads the chat logs Claude Code already keeps in `~/.claude/projects` on your
Mac. Nothing is sent anywhere.

## What it shows

- **Overview**: a calendar of daily usage (brighter blue = more tokens), favorite
  model, sessions, active days, total tokens, longest session, most active day.
- **Tokens**: input, output, cache read, cache write and total.
- **Models**: each model's share of your tokens.
- A time range switch: all time, last 30 days, last 7 days.

## How it behaves

- Floats above other windows, and by default only shows while the Claude desktop
  app is in front.
- Pops open whenever Claude is launched.
- **Option-Command-U** opens and closes it from any app.
- A grid icon in the menu bar has show/hide, refresh, Open at Login and quit.
- **Open at Login** writes a launch agent to
  `~/Library/LaunchAgents/local.usage-stats.plist` that runs
  `open -g "Usage Stats.app"` when you log in (more reliable than a login item
  for a locally built, ad-hoc signed app). Turn it off from the same menu, or:

  ```bash
  "$HOME/Applications/Usage Stats.app/Contents/MacOS/UsageStats" --login-off
  ```
- Drag it anywhere; it remembers its position. Follows light and dark mode.

## Build

Requires macOS 13 or later on Apple silicon, and Xcode (for `swiftc`).

```bash
./build.sh
```

This builds `Usage Stats.app` into `~/Applications`. Open it from there.

## Optional terminal command

`stats` is a small wrapper script. Copy it somewhere on your `PATH`:

```bash
cp stats ~/.local/bin/stats
```

Then `stats` toggles the window, and `stats show`, `stats hide` and `stats quit`
do what they say.

## Notes

- Token counts are deduplicated by reply, so resumed or forked chats are not
  counted twice.
- The app writes a short startup log (whether the shortcut and login agent are
  set up) to `~/Library/Application Support/Usage Stats/log.txt`.
- Parsed results are cached in `~/Library/Application Support/Usage Stats/`, so
  only changed logs are reread.
- Not affiliated with Anthropic.
