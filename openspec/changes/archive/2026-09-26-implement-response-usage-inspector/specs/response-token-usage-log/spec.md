## MODIFIED Requirements

### Requirement: Inspect and group response usage
The app SHALL let the user inspect response-level token records for a selected local calendar day in Responses, Model, or Session view. Responses SHALL be the default view and SHALL be sorted newest first. The app SHALL compute displayed totals from each response's `usage` values, without adding cached-input or reasoning-output breakdowns a second time.

In Responses view, each row SHALL show the response ID, time, model, reasoning effort, input tokens, output tokens, and total tokens. An expansion SHALL show all available token dimensions and the session and thread identifiers.

In Model view, the app SHALL show one list row for each model with recorded usage. A collapsed row SHALL show the model name and aggregate total tokens. Expanding the row SHALL show input, output, and total tokens for every reasoning effort listed as supported for that model in the app's local capability registry. A supported effort with no responses in the selected period SHALL show zero for each token count. Responses whose effort is missing or unrecognized SHALL remain visible under an Unknown effort row. If a model has no capability entry, the app SHALL avoid presenting observed efforts as a complete capability list and SHALL indicate that its capability list is unavailable.

In Session view, the app SHALL group responses by session and show any available session name. Expanding a session SHALL reveal its threads; expanding a thread SHALL reveal that thread's response rows.

#### Scenario: Browse raw responses
- **WHEN** the user selects Responses for a day containing response records
- **THEN** the app shows the day's responses newest first with input, output, and total token counts, and each row can expand to show all other available token dimensions

#### Scenario: Expand a model row
- **WHEN** the user selects Model and expands a model row
- **THEN** the app shows one breakdown for each reasoning effort supported by that model, with input, output, and total values aggregated from that effort's responses

#### Scenario: Show an unused supported effort
- **WHEN** a model supports an effort but has no responses at that effort in the selected period
- **THEN** the expanded model row shows zero input, output, and total tokens for that effort

#### Scenario: Preserve unknown effort records
- **WHEN** a response has no reasoning-effort value or a value not recognized by the app
- **THEN** the response remains visible in Responses view and contributes to an Unknown effort row in its model row

#### Scenario: Capability list is unavailable for a model
- **WHEN** the app has records for a model with no entry in its local capability registry
- **THEN** the app shows the observed effort groups and indicates that the full supported-effort list is unavailable

#### Scenario: Expand sessions into threads and responses
- **WHEN** the user selects Session and expands a session and one of its threads
- **THEN** the app shows the session's threads and the selected thread's response rows with their response-level token details

#### Scenario: Session name is unavailable
- **WHEN** the selected day's response records belong to a session with no local name metadata
- **THEN** the app uses a stable session identifier as the session label and still allows the session to expand

#### Scenario: Selected day has no records
- **WHEN** the user selects a local calendar day with no response records
- **THEN** the app displays an empty state rather than a fabricated zero-usage response

## ADDED Requirements

### Requirement: Resolve session names from local metadata
The app SHALL resolve session display names from the local Codex session index using session identifiers. It SHALL read only the index fields required to associate an identifier with its thread name, SHALL NOT copy conversation content into the response log, and SHALL continue to show sessions if the index is missing or unreadable.

#### Scenario: Session index contains a name
- **WHEN** a response record's session identifier matches an entry in the local session index
- **THEN** Session view uses that entry's thread name as the session label

#### Scenario: Session index cannot be read
- **WHEN** the local session index is missing, unreadable, or has no matching entry
- **THEN** Session view falls back to the session identifier without failing to display usage

### Requirement: Keep inspector interactions responsive
The app SHALL prepare the selected day's filtered records, group summaries, totals, and session-name lookup away from the main UI actor. It SHALL reuse that prepared data when the user changes grouping or expands a row, and SHALL refresh it only when the selected day or source response records change.

#### Scenario: Switch grouping with an unchanged day
- **WHEN** the user switches grouping modes without changing the selected day or source response records
- **THEN** the app renders the selected mode from the existing prepared data without rereading the session index or regrouping the full response log on the main UI actor

#### Scenario: Source data changes
- **WHEN** the selected day or source response records change while the inspector is open
- **THEN** the app prepares a new snapshot away from the main UI actor and displays a loading state until the matching snapshot is ready
