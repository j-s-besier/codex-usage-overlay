## 1. Change Detection

- [x] 1.1 Refactor the local counter to reconcile the session tree and process selected changed JSONL files from stored offsets.
- [x] 1.2 Add an FSEvents watcher for file-level changes, with batched path handling and explicit start/stop lifecycle.
- [x] 1.3 Reconcile on startup, local midnight, wake, dropped events, and structural file changes; retain a polling fallback if watcher startup fails.
- [x] 1.4 Add per-file vnode write/extend monitoring for existing current files and newly discovered session files; retain FSEvents for discovery and recovery, and close descriptors on shutdown or replacement.

## 2. Counter and UI Integration

- [x] 2.1 Decouple local token-count updates from the 30-second limit and response-log refresh.
- [x] 2.2 Keep the shared menu bar and popover value, CSV write throttle, and existing animation behavior.
- [x] 2.3 Make explicit manual refresh reconcile the daily total while preserving the timer's event-driven counting behavior.

## 3. Verification

- [x] 3.1 Test appended token events, incomplete lines, unrelated lines, truncation/replacement, dropped-event reconciliation, and day rollover.
- [x] 3.2 Verify that limit fetching and response-log synchronization remain on the 30-second cadence.
- [x] 3.3 Verify watcher-to-counter latency under two seconds and that steady-state updates process changed paths without rescanning the session tree.
- [x] 3.4 Run the test suite, build, and strict OpenSpec validation.
- [x] 3.5 Verify repeated appends from held-open writers for existing, newly discovered, and replaced session files, including prompt updates before writer close and watcher stop cleanup. Focused watcher/counter verification: 13 tests passed.
- [x] 3.6 Verify the rebuilt menu bar app with a test reply; the displayed daily total updated after the response.
