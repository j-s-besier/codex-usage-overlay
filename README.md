# Codex Usage Menu Bar Prototype

A small macOS menu bar extra that shows the remaining Codex usage reported by the local Codex App Server.

## Install the app from a ZIP

Download the `CodexUsageMenuBar-arm64.zip` build for Apple Silicon, the `x86_64` build for Intel, or a `universal` build when one is provided. Unzip it and drag **Codex Usage Menu Bar.app** to `/Applications` (or `~/Applications`), then double-click the app. It runs in the menu bar without a Dock icon. Downloaded builds require macOS 13 or later and the signed-in `codex` CLI; Swift and a source checkout are not required.

These packages are **ad-hoc signed and not notarized**. Gatekeeper may block a downloaded build. For a build you trust, use the macOS **System Settings → Privacy & Security → Open Anyway** option after attempting to open it. The package script does not use any personal or company signing certificate. No download is published by the build script; maintainers distribute the generated ZIP separately.

For account limits, the app finds `codex` in `/opt/homebrew/bin`, `/usr/local/bin`, or its process `PATH`. Finder does not inherit your shell environment. For a custom CLI location, set `CODEX_CLI_PATH` with `launchctl setenv CODEX_CLI_PATH /absolute/path/to/codex` before launching the app. Likewise, set `CODEX_HOME` with `launchctl setenv` if your logs use a custom location. These session settings need to be reapplied after logout. Sign in using `codex login` if needed.

To follow Codex automatically and start monitoring at login, run the script from the **installed app** in Terminal:

```sh
"/Applications/Codex Usage Menu Bar.app/Contents/Resources/install-companion.sh"
```

Quit any manually launched copy before installing the companion. The companion records the installed app's absolute path; install the app in its final location first, and rerun the command after moving it. Remove the companion before deleting the app:

```sh
"/Applications/Codex Usage Menu Bar.app/Contents/Resources/uninstall-companion.sh"
```

Use your actual app path if you installed it elsewhere. The bundled scripts need neither Swift nor this repository. The companion checks for Codex every three seconds and starts or stops the menu bar process accordingly.

## Build a downloadable package

On macOS with Swift 5.9 or later:

```sh
./package-app.sh
# Optional build for both Apple Silicon and Intel:
ARCH=universal ./package-app.sh
```

The script builds in release mode, assembles and verifies an ad-hoc signed app bundle, and creates `dist/Codex Usage Menu Bar.app` and `dist/CodexUsageMenuBar-<architecture>.zip`. Native architecture is the default; `ARCH=arm64` and `ARCH=x86_64` select a specific target. Each build replaces the app bundle and the ZIP for that architecture. Generated app bundles, `dist/`, environment secrets, and local usage data are ignored by Git. A notarized public download would require a separate Developer ID signing and notarization process.

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

The menu bar shows the account's reported token total for the current local date and the remaining percentage for the primary Codex limit window. Click it to see the exact token count, reset times, any longer limit window, an **Open CSV** button for daily totals, and an **Inspect** button for response-level usage by response, model, or session. The local token total updates when Codex writes session-log changes (normally within two seconds); account-limit fetching and response-log synchronization run every 30 seconds. Click the refresh icon to fetch usage and reconcile the token total immediately. Quit from the menu bar app's Dock menu or Activity Monitor.

## Data and access

The prototype starts `codex app-server` locally and calls `account/rateLimits/read`. It reads token-count metadata from local Codex session logs; conversation text and tool input/output are not retained. The daily total resets at local midnight. If the CLI is not signed in, the limit is unavailable, but local token logging can still work.

The App Server reports remaining quota as a percentage of each available Codex limit window. The token total is local session token activity, not an exact conversion to Pro limit consumption. The local total responds to session-log writes and resets at local midnight; the quota percentage refreshes every 30 seconds. This prototype appears in the macOS menu bar and does not modify the Codex app.

Daily totals are saved in `~/.codex/daily-token-usage.csv` as one `date,tokens_compact,tokens,last_updated_at` row per local calendar day. `tokens` stays an exact integer for spreadsheet calculations; `tokens_compact` shows the rounded display form such as `12.3K`, `4.5M`, or `1.2B`. The row is updated at most every five minutes while the total changes, immediately when a new day is first seen, and once more when the app exits. At startup, the counter rebuilds today's total from local session logs and refreshes today's CSV row, recovering after an unclean exit. The timestamp is ISO 8601.

Response-level usage is saved in `~/.codex/response-token-usage.jsonl`, with a separate `response-token-usage.state.json` checkpoint. Each JSONL row represents one Codex response and includes source IDs, timestamp, model, reasoning effort, and the reported input, cached-input, cache-write, output, reasoning-output, and total token values. Cached input and reasoning output are breakdowns of input/output, not extra tokens to add to the total. The app imports the current local day's existing responses on first run, then incrementally catches up from session logs after restarts and avoids duplicate response IDs. This history persists across days. Both paths use `$CODEX_HOME` when set and otherwise use `~/.codex`. The response log contains usage metadata only; it is not a credit or quota attribution log.
