## Why

The daily token count currently refreshes on the same 30-second cycle as usage-limit requests and response-log synchronization. This delays visible token updates while working, and lowering the shared timer would repeat unrelated file scans and Codex App Server launches.

## What Changes

- Update the local daily token counter in response to changes in Codex session JSONL files, targeting a visible update within two seconds under normal operation.
- Reconcile the counter at app startup, local midnight, and when the file watcher reports dropped or invalidated events.
- Keep usage-limit fetching and response-log synchronization on their existing 30-second cadence.
- Preserve incremental byte reading, token-only parsing, the five-minute CSV write throttle, and the existing counter display animation.

## Capabilities

### New Capabilities
- `daily-token-counter-refresh`: Defines prompt local token-count updates driven by session-log changes and reconciliation behavior.

### Modified Capabilities
None.

## Impact

- `Sources/CodexUsageCore/LocalTokenUsageCounter.swift`: support reconciliation and processing changed session files.
- `Sources/CodexUsageOverlay/CodexUsageOverlayApp.swift`: separate local token updates from the 30-second limit and response-log refresh.
- `Sources/CodexUsageCore/SessionLogChangeWatcher.swift` and tests for changes, reconciliation, partial lines, and file replacement.
- Uses macOS Core Services file-system events; no third-party dependency or new credential access.
