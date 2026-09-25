## 1. Parse per-response usage metadata

- [x] 1.1 Add a response usage record model for timestamp, source IDs, model, effort, and token fields.
- [x] 1.2 Parse `token_usage_record.payload.usage` and associate each record with the matching preceding `turn_context` by turn ID.
- [x] 1.3 Preserve missing model or effort as unknown and avoid reading or retaining message and tool content.

## 2. Persist and recover the app-owned JSONL log

- [x] 2.1 Add append-only JSONL persistence under `CODEX_HOME` or `~/.codex` with a versioned record format.
- [x] 2.2 Add startup and periodic source scanning with byte-offset checkpoints, partial-line handling, and response-ID deduplication.
- [x] 2.3 On first run, import only current-local-day records; on later runs, catch up from saved checkpoints without rewriting prior log rows.

## 3. Inspect and group response usage

- [ ] 3.1 Add a response usage inspector reachable from the menu bar app.
- [ ] 3.2 Display response records and daily groups by model and reasoning effort, including unknown metadata groups.
- [ ] 3.3 Show token breakdowns without adding cached input or reasoning output to totals a second time.

## 4. Verify behavior

- [ ] 4.1 Add focused fixture-based tests for response parsing, turn-context association, overlapping token fields, and cumulative-versus-per-response usage.
- [ ] 4.2 Add recovery tests for duplicate scans, restart catch-up, truncated files, and incomplete trailing lines.
- [ ] 4.3 Build the macOS app and verify the inspector can open and group a populated local response log.
