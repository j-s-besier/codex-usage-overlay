## Context

The menu bar app already scans local Codex session JSONL files every 30 seconds to build a daily total. A response-level record is available in each source file as `token_usage_record.payload.usage`; the same envelope carries response, turn, session, and thread identifiers. The matching `turn_context` entry provides model and effort. The source also contains cumulative turn and thread snapshots, which must not be summed as individual responses.

The app must keep operating without Codex session access being available, must not retain conversation content, and must recover usage written while the app is stopped. The user's requested scope excludes quota and limit attribution.

## Goals / Non-Goals

**Goals:**
- Persist one local app-owned JSONL row per source response usage record.
- Associate response usage with model and reasoning effort when the turn context is available.
- Preserve each source token field without double-counting cached-input or reasoning-output subsets.
- Recover missed responses and avoid duplicates across app restarts.
- Let the user inspect response rows and view daily totals grouped by model and effort.

**Non-Goals:**
- Determine or estimate account quota, credits, or limit consumption.
- Store or display prompt text, assistant text, tool input, or tool output.
- Change the existing menu-bar quota display or daily total format.
- Build a separate daemon or scheduled script.

## Decisions

### Process session logs in the app

Extend the existing Swift session-log reader and run response ingestion alongside its current refresh cycle. Process source files at startup and every 30 seconds; retain byte offsets and incomplete trailing lines so unchanged file contents are not repeatedly decoded. This reuses the app's existing lifecycle and avoids a second process to install and supervise.

### Use one response's `usage` object

Treat each `token_usage_record` as one response and copy its `usage` object into the app-owned record. Do not sum `turn_token_usage` or `thread_token_usage`, because those are cumulative snapshots. Associate the record with the most recent preceding `turn_context` for its `turn_id`; write `unknown` for model or effort if no matching metadata exists. Store the source timestamp without alteration and derive local calendar dates when presenting daily groups.

Preserve `input_tokens`, `cached_input_tokens`, `cache_write_input_tokens`, `output_tokens`, `reasoning_output_tokens`, and `total_tokens` exactly as reported. Cached input is a breakdown of input, and reasoning output is a breakdown of output; they are not additional totals.

### Write an app-owned JSONL file and checkpoint

Append records to `response-token-usage.jsonl` in the configured Codex home directory (`CODEX_HOME`, falling back to `~/.codex`). Each line is a self-contained record with a schema version and source identifiers. Use the source session ID plus response ID as the idempotency key when both are present. Maintain a local checkpoint file for source-file byte offsets and initial scan state. Acquire an operating-system file lock while refreshing the log, reading/updating checkpoints, and appending records so two app instances cannot race. Write response rows before advancing the checkpoint; on recovery, use existing response IDs to skip rows appended before an interruption.

On the first run, import only records for the current local calendar day, matching the counter's existing daily scope. On later runs, read from saved offsets so records written while the app was stopped are caught up, even when the app restarts on a later day. If a source file shrinks or rotates, restart reading that file and rely on response IDs to prevent duplicates.

### Inspect rows and group by model and effort

Add response usage inspection to the app UI. Show response-level records and daily aggregate totals grouped by model and effort. Use `unknown` as a visible group when source metadata is missing. Compute aggregates from the per-response `usage` values, not cumulative source snapshots. Keep the existing CSV history action available for daily totals.

### Keep log content local and limited

Write only timestamps, source identifiers, model/effort labels, and usage numbers. Do not serialize source payloads wholesale. Do not make network requests for response ingestion or display. The log grows over time; initial implementation keeps its records so historical daily views remain available.

## Risks / Trade-offs

- [Codex may change session JSONL field names or event ordering] → Decode only the required metadata fields, tolerate missing fields, and mark unavailable model/effort values as unknown rather than dropping usage.
- [A crash may occur between appending a row and saving a checkpoint] → Append complete JSONL lines before checkpoint advancement and deduplicate from persisted response IDs during recovery.
- [Two app instances may run at once] → Serialize collection through a local operating-system file lock and reload the shared checkpoint and any appended log rows while holding it.
- [The response log grows with use] → Keep rows compact and metadata-only; defer retention controls until there is evidence they are needed.
- [Session and response identifiers can reveal local activity structure] → Keep the file under the user's Codex home directory and never include conversation content or transmit it.
- [Usage counters may be misunderstood as quota credits] → Label these as observed token counts and make no quota/limit claims in the inspector.

## Migration Plan

1. On first launch with the new version, create the app-owned log and checkpoint in the configured Codex home directory and import current-day response records.
2. Continue incremental ingestion on startup and the existing refresh interval.
3. Keep the existing daily CSV untouched; no migration or rewrite is needed.
4. If the feature is rolled back, leave the local response JSONL file intact for inspection or manual removal.

## Open Questions

- None blocking proposal readiness. The initial history boundary is the current local day on first run; later runs catch up from checkpoints.
