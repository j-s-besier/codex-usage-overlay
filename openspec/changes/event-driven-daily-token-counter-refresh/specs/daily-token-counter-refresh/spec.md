## ADDED Requirements

### Requirement: Update the daily total when session logs change
The application MUST update the displayed daily token total from changed Codex session JSONL files without waiting for the 30-second usage-limit refresh. Under normal operation, a file change containing new token-count data MUST be reflected within two seconds.

#### Scenario: A session appends token-count data
- **WHEN** a watched session JSONL file receives a complete token-count event for the current local day
- **THEN** the daily total is recalculated from the newly appended bytes and the counter display is updated within two seconds under normal operation

#### Scenario: A session appends unrelated data
- **WHEN** a watched file changes but contains no new complete token-count event
- **THEN** the parser retains any incomplete line for a later append and the daily total remains unchanged

#### Scenario: A session writer remains open across replies
- **WHEN** an existing or newly discovered session file receives successive complete token-count events through a writer that stays open between appends
- **THEN** each append updates the daily counter within two seconds under normal operation without waiting for the writer to close

#### Scenario: Watcher stops with session writers still open
- **WHEN** the session watcher stops while producers retain open writers
- **THEN** the watcher cancels pending delivery and per-file sources, closes its monitoring descriptors, and emits no further change batches

### Requirement: Reconcile file state to recover correctness
The application MUST reconcile the daily counter with current session files at startup, at local midnight, and when file-system events indicate dropped, renamed, removed, or otherwise invalidated file state.

#### Scenario: Application starts
- **WHEN** the local token counter starts watching the session directory
- **THEN** it performs a full reconciliation so data written before the watcher started is included

#### Scenario: Local day changes
- **WHEN** the local calendar day changes
- **THEN** the counter resets its per-file state and reconciles the new day's session files

#### Scenario: File events are dropped or a file is replaced
- **WHEN** the watcher reports dropped events or an event indicates a file rename, removal, or replacement
- **THEN** the counter reconciles file state so deleted or truncated files do not leave stale tokens in the daily total

#### Scenario: User requests manual refresh
- **WHEN** the user explicitly refreshes usage while the file watcher is running
- **THEN** the daily counter performs a full reconciliation to recover any missed changes

### Requirement: Keep unrelated refresh and persistence behavior stable
Faster token updates MUST NOT increase the cadence of usage-limit fetching or response-log synchronization, and MUST preserve the existing CSV write throttle and token-only parsing behavior.

#### Scenario: Session files change between limit refreshes
- **WHEN** token-count events arrive between two 30-second refresh cycles
- **THEN** the local counter updates from file events while limit fetching and response-log synchronization remain on their 30-second cadence

#### Scenario: Daily CSV persistence is due
- **WHEN** the local total changes
- **THEN** the existing five-minute CSV write throttle and local-day rollover write behavior remain in effect

#### Scenario: Session event includes unrelated conversation content
- **WHEN** changed session bytes contain message text or tool output alongside token metadata
- **THEN** the counter extracts only token-count metadata and does not retain or emit message text or tool output
