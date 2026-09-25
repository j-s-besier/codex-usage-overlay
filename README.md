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

The menu bar shows the account's reported token total for the current local date and the remaining percentage for the primary Codex limit window. Click it to see the exact token count, reset times, any longer limit window, an **Open CSV** button for daily totals, and an **Inspect** button for response-level usage grouped by model and reasoning effort. Usage refreshes every 30 seconds; click the refresh icon to update sooner. Quit from the menu bar app's Dock menu or Activity Monitor.

## Data and access

The prototype starts `codex app-server` locally and calls `account/rateLimits/read`. It reads token-count metadata from local Codex session logs; conversation text and tool input/output are not retained. The daily total resets at local midnight. If the CLI is not signed in, the limit is unavailable, but local token logging can still work.

The App Server reports remaining quota as a percentage of each available Codex limit window. The token total is local session token activity, not an exact conversion to Pro limit consumption. Both values refresh every 30 seconds. This prototype appears in the macOS menu bar and does not modify the Codex app.

Daily totals are saved in `~/.codex/daily-token-usage.csv` as one `date,tokens_compact,tokens,last_updated_at` row per local calendar day. `tokens` stays an exact integer for spreadsheet calculations; `tokens_compact` shows the rounded display form such as `12.3K`, `4.5M`, or `1.2B`. The row is updated at most every five minutes while the total changes, immediately when a new day is first seen, and once more when the app exits. At startup, the counter rebuilds today's total from local session logs and refreshes today's CSV row, recovering after an unclean exit. The timestamp is ISO 8601.

Response-level usage is saved in `~/.codex/response-token-usage.jsonl`, with a separate `response-token-usage.state.json` checkpoint. Each JSONL row represents one Codex response and includes source IDs, timestamp, model, reasoning effort, and the reported input, cached-input, cache-write, output, reasoning-output, and total token values. Cached input and reasoning output are breakdowns of input/output, not extra tokens to add to the total. The app imports the current local day's existing responses on first run, then incrementally catches up from session logs after restarts and avoids duplicate response IDs. This history persists across days. Both paths use `$CODEX_HOME` when set and otherwise use `~/.codex`. The response log contains usage metadata only; it is not a credit or quota attribution log.
