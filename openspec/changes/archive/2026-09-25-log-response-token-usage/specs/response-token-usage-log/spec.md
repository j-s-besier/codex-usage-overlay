## ADDED Requirements

### Requirement: Persist one metadata record per model response
The counter SHALL read per-response usage from local Codex session logs and persist one JSONL record for each response that contains token usage. Each record SHALL include the source timestamp, response ID, turn ID, session and thread IDs when available, model, reasoning effort, and the available input, cached-input, cache-write-input, output, reasoning-output, and total-token values. Missing model or effort metadata SHALL NOT cause an otherwise valid usage record to be discarded.

#### Scenario: A response has complete metadata
- **WHEN** a session log contains a response usage record and matching turn context
- **THEN** the app-owned log contains one record with that response's usage and matching model and effort

#### Scenario: A response lacks model or effort metadata
- **WHEN** a session log contains usage but the corresponding model or effort cannot be determined
- **THEN** the app-owned log records the usage and marks the unavailable metadata as unknown

#### Scenario: Token dimensions overlap
- **WHEN** the app records cached input or reasoning output values
- **THEN** it preserves those values as breakdowns and does not add them a second time to the reported total

### Requirement: Recover response logging without duplicates
The counter SHALL recover response records written to source session logs while the app was not running. It SHALL avoid writing a response more than once, using stable source identifiers when available, and SHALL continue logging after restart or partial source-file writes.

#### Scenario: First run begins today's response history
- **WHEN** the app-owned response log does not yet exist
- **THEN** the app records available response usage from the current local day without importing older history

#### Scenario: App restarts after missing source updates
- **WHEN** source session logs contain responses written since the app's last successful scan
- **THEN** the app-owned log catches up with those responses and preserves prior log entries

#### Scenario: A source record is processed again
- **WHEN** startup recovery or a repeated scan encounters a response already present in the app-owned log
- **THEN** the app does not append a duplicate response record

#### Scenario: A source file ends with an incomplete JSONL line
- **WHEN** the app reads a source file whose final record is incomplete
- **THEN** the app waits for the line to complete before recording it

### Requirement: Keep response usage local and metadata-only
The counter SHALL store the response log under the configured Codex home directory and SHALL NOT copy prompt text, assistant text, or tool input/output into the app-owned log. Logging SHALL use local files only and SHALL NOT make network requests for response usage.

#### Scenario: The app writes a response record
- **WHEN** the app persists response usage
- **THEN** it writes token metadata and identifiers locally without message or tool content

### Requirement: Inspect and group response usage
The app SHALL let the user inspect response-level token records and group usage by model and reasoning effort for a selected local calendar day. Grouped totals SHALL be computed from per-response usage records and SHALL retain token dimensions without double-counting overlapping breakdowns.

#### Scenario: The user groups a day's usage by model and effort
- **WHEN** the user selects a local calendar day and groups response usage by model and reasoning effort
- **THEN** the app displays per-group totals and allows the underlying response records to be inspected

#### Scenario: A day has no response records
- **WHEN** the user selects a local calendar day with no logged responses
- **THEN** the app displays an empty state rather than a fabricated zero-usage response
