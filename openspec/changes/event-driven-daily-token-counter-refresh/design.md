## Context

Before this change, `UsageStore.refresh()` ran every 30 seconds and performed three jobs: reading the local token total, calling `ResponseUsageLogStore.synchronize()`, and starting a fresh `codex app-server` process for `account/rateLimits/read`. The token counter read new bytes incrementally, but it still enumerated session files and checked their metadata each time. Response-log synchronization also enumerated session paths to find appended bytes.

The target is to make the daily token display respond promptly without running the other two jobs more often. The package targets macOS 13 or later and has no external runtime dependencies.

## Goals / Non-Goals

**Goals:**
- Refresh the daily token total on session-file changes, with a two-second target under normal operation.
- Keep the existing 30-second cadence for limit reads and response-log synchronization.
- Recover correctly after app startup, local midnight, dropped events, file replacement, and app wake.
- Continue parsing only token metadata and preserve CSV write throttling.

**Non-Goals:**
- Increase the frequency of Codex App Server calls or response-log synchronization.
- Change the meaning of the token total, daily log format, or display animation.
- Watch or parse files outside the configured Codex sessions directory.

## Decisions

- Watch the `sessions` directory tree with Core Services `FSEventStream` for path discovery and structural recovery. FSEvents can report the first write and then defer further modification notifications until the producer closes its descriptor; Codex keeps session writers open between replies. Add `DispatchSourceFileSystemObject` vnode sources for `.write` and `.extend` on current JSONL files so repeated appends update the total while the producer remains open. Debounce both event types on one serial utility queue. [Apple: FSEventStreamCreate](https://developer.apple.com/documentation/coreservices/1443980-fseventstreamcreate), [Apple: Dispatch file-system source](https://developer.apple.com/documentation/dispatch/dispatchsourcefilesystemobject)
- Install vnode sources for today's existing session files at watcher startup and for current files discovered through FSEvents. Retain attached sources across midnight for writers that remain open. Track device/inode identity, cancel and reattach on replacement, and handle vnode rename/delete/revoke events as reconciliation triggers. Open read-free `O_EVTONLY` descriptors with close-on-exec; cancellation handlers close every descriptor. Serialize startup, stop, and callback state to prevent stale deliveries or leaked sources.
- Keep `LocalTokenUsageCounter` in the core module as the parser and source of truth. Refactor its current full enumeration into explicit reconciliation plus per-file incremental processing. Normal modification events process only affected JSONL paths using stored byte offsets; complete lines are parsed and incomplete tails remain buffered.
- Start the watcher and perform an initial reconciliation so writes before stream startup are not lost. Schedule a reconciliation at the next local midnight and after wake. Reconcile whenever FSEvents signals dropped events or structural changes such as rename, removal, or replacement. This uses event notifications for the common case and a full scan only for recovery and day rollover.
- Split local token-counter updates from the scheduled refresh. Keep the timer at 30 seconds for rate limits and response-log synchronization. The watcher publishes updated totals directly to the shared `UsageStore` state, so the menu bar and popover update without waiting for that timer. Explicit manual refresh also reconciles the daily counter, even while the watcher is running, providing a recovery path without adding full scans to the normal timer.
- Keep CSV persistence policy unchanged: token totals are written at most once every five minutes when changed, plus existing day-boundary and shutdown writes.
- Watch only the configured `CODEX_HOME/sessions` tree. Continue parsing token-count fields from appended JSONL bytes; do not log file paths or retain conversation text.

### Alternatives considered

- **Poll the whole refresh every one or two seconds:** Rejected because it would repeat session-directory enumeration and launch a Codex App Server process up to 30 times as often.
- **Poll token-file metadata every one or two seconds:** Easier to implement and a reasonable fallback, but it still stats the session tree on every poll. It may be preferable if FSEvents complexity proves disproportionate in testing.
- **Use only per-file Dispatch sources:** Insufficient for discovering new files. Combine sources for prompt appends with FSEvents for creation, renames, dropped events, and recovery.
- **Use only FSEvents:** Rejected after a held-open-writer probe showed that spaced appends after the first write were not reported until the writer closed. A regression must keep the writer open while awaiting each updated total.

## Risks / Trade-offs

- [FSEvents may defer modifications or report dropped events] → Use vnode sources for repeated appends while writers remain open; process the latest file state by offset and reconcile on dropped-event flags, startup, midnight, wake, and explicit manual refresh.
- [Per-file sources consume descriptors] → Attach sources to current files rather than the entire historical log archive; close descriptors on cancellation and watcher shutdown. Existing sources remain attached across midnight to preserve active writers.
- [File replacement at the same path may invalidate the byte offset] → Treat structural events as reconciliation triggers and verify file identity or truncation before continuing an offset.
- [Event bursts can cause redundant UI work] → Coalesce paths on a serial queue and publish only when the computed total changes.
- [Watcher startup can race with a newly written session file] → Start watching before or alongside initial reconciliation, then drain any queued changed paths after reconciliation.
- [The new watcher creates lifecycle and recovery code] → Keep it isolated in a small type with explicit start/stop behavior and use the existing scanner as the recovery path.

## Migration Plan

No persisted data migration is needed. Existing CSV content, checkpoints, and response logs remain valid. If the watcher fails to start, the app can fall back to the existing 30-second token refresh while leaving limit and response-log refreshes unchanged. Reverting the watcher restores the current polling behavior.

## Open Questions

- Confirm the event-to-display target on supported hardware under normal load; the proposal uses two seconds as the acceptance target.
- Verify whether the current user-level launch mechanism needs any explicit wake or restart lifecycle hook beyond FSEvents recovery and startup reconciliation.
