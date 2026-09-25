# Codex Usage Menu Bar Prototype

A small macOS menu bar extra that shows the remaining Codex usage reported by the local Codex App Server.

## Run

Requirements: macOS 13 or later, Swift 5.9 or later, and the `codex` CLI signed into the same ChatGPT account as the Codex app.

From this folder, run:

```sh
./run.sh
```

To have the menu bar app follow Codex automatically, install its per-user LaunchAgent:

```sh
./install-companion.sh
```

The agent checks for the Codex desktop process every three seconds, starts the menu bar app while Codex is open, and stops it when Codex exits. It also starts monitoring at login. Remove the automation with `./uninstall-companion.sh`.

The menu bar shows the account's reported token total for the current local date and the remaining percentage for the primary Codex limit window. Click it to see the exact token count, reset times, any longer limit window, and an **Open CSV** button for the daily token history. Both usage values refresh every 30 seconds; click the refresh icon to update them sooner. Quit from the menu bar app's Dock menu or Activity Monitor.

## Data and access

The prototype starts `codex app-server` locally and calls `account/rateLimits/read`. It reads only token-count metadata from local Codex session logs to total tokens processed today; conversation text and tool output are skipped. The token counter resets at local midnight. If the CLI is not signed in, the limit is unavailable, but the local token counter can still work.

The App Server reports remaining quota as a percentage of each available Codex limit window. The token total is local session token activity, not an exact conversion to Pro limit consumption. Both values refresh every 30 seconds. This prototype appears in the macOS menu bar and does not modify the Codex app.

Daily totals are saved in `~/.codex/daily-token-usage.csv` as one `date,tokens_compact,tokens,last_updated_at` row per local calendar day. `tokens` stays an exact integer for spreadsheet calculations; `tokens_compact` shows the rounded display form such as `12.3K`, `4.5M`, or `1.2B`. The row is updated at most every five minutes while the total changes, immediately when a new day is first seen, and once more when the app exits. At startup, the counter rebuilds today's total from local session logs and refreshes today's CSV row, recovering after an unclean exit. The timestamp is ISO 8601.
