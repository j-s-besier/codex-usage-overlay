## Context

The app already writes metadata-only `ResponseTokenUsageRecord` rows and loads them into `UsageStore.responseRecords`. `ResponseUsageInspectorView` currently offers a selected-day picker and disclosures grouped by model and effort. The approved HTML preview adds a raw response list, compact per-model summaries, and nested session → thread → response disclosures.

Response records include model, effort, session ID, thread ID, timestamp, and token dimensions. The local Codex `session_index.jsonl` contains `id` and `thread_name`; a local shape check confirmed the index IDs match session IDs. The app currently has no model-to-supported-effort capability registry. The preview's records and session names are synthetic and must not be used as production data.

## Goals / Non-Goals

**Goals:**
- Recreate all three preview modes in the existing native SwiftUI inspector and keep the local-day picker.
- Show all supported efforts for known models, including zero counts, while keeping missing or unrecognized effort records visible.
- Use local session names and nested thread grouping without retaining conversation content.
- Preserve accurate totals by summing per-response values only.

**Non-Goals:**
- Change source-log collection, response JSONL schema, daily CSV, menu-bar display, or quota reporting.
- Add a web view, external dependency, network request, or server.
- Import preview sample data into the app.

## Decisions

### Keep the inspector native in SwiftUI

Adapt `ResponseUsageInspectorView` and add small focused presentation helpers rather than embedding the HTML in `WKWebView`. The app already uses SwiftUI and has typed records, date filtering, and native disclosure controls; keeping one native UI avoids a JavaScript bridge and duplicate interaction state. The HTML remains the visual reference.

### Add an explicit local model-effort capability registry

Keep an ordered, model-keyed registry with display labels and supported effort identifiers. Build model rows from the union of the registry's supported efforts and the selected day's observed efforts, preserving an Unknown row for missing/unrecognized values. Initialize zero totals only for registry-supported efforts. For an unrecognized model, show observed efforts and a clear capability-list-unavailable state rather than claiming that observed efforts are exhaustive or inventing zero rows. This registry is app data, not token data, and can be revised as supported models change.

### Resolve session names from the local Codex session index

Read `session_index.jsonl` from the configured `CODEX_HOME` (or `~/.codex`) and build a transient map from `id` to `thread_name`. Parse only those fields; do not copy names into `response-token-usage.jsonl` or read conversation entries. If the file or matching entry is unavailable, use the session ID as a stable fallback label. Session and thread groups are computed from the existing response records.

### Keep grouping and totals derived from response records

Use `timestamp` to filter the chosen local day and sort response, session, thread, and model breakdown records newest first. Derive session, thread, and model totals from each response's `usage.totalTokens`; derive per-effort input/output/total from that effort's response rows. Cached input and reasoning output remain breakdowns and are never added to totals again. Null values remain unavailable (`—`); efforts with no records get explicit zeroes.

### Prepare one day-scoped snapshot off the UI thread

Filtering and sorting the full log, parsing timestamps, building all group summaries, calculating totals, and reading `session_index.jsonl` can take noticeable time as history grows. Prepare one immutable snapshot on a background task keyed by selected day and response-record revision. Reuse its response, model, and session summaries when the user switches modes or expands a row; rebuild only when the day or source records change. Show a brief loading state during a rebuild.

### Match the preview's information hierarchy and token colors

Use three grouping controls: Responses, Model, and Session. Responses show input in green, output in red, total in blue, and expanded token dimensions in yellow. Model mode uses a compact full-width list with one expandable row per model, a total and Show more control, then effort-level input/output/total rows. Session mode shows the session label and totals, expands to threads, and then to response rows. Unknown effort labels remain neutral. Use SwiftUI accessibility labels and disclosure state so colors are not the only indication of metric type.

## Risks / Trade-offs

- [The local capability registry can become stale as models or supported efforts change] → Keep the registry centralized, use canonical model IDs, and display an unavailable state for unlisted models instead of fabricating capability data.
- [The session index can be absent or malformed] → Parse defensively, keep response usage visible, and fall back to the stable session ID.
- [A larger record set can make nested views expensive] → Filter by selected day before grouping, prepare summaries away from the main thread, and use lazy SwiftUI stacks for expanded content.
- [A color distinction can be inaccessible] → Retain explicit Input, Output, Total, and token-dimension labels and preserve adequate text contrast.
- [Session names can reveal user-authored titles] → Read only the local index's identifier and display-name fields in memory; do not persist them in the usage log or send them elsewhere.

## Migration Plan

No response-log migration is required. Ship the view and capability registry with the app, load session names on demand from the existing Codex home directory, and use ID fallback when lookup is unavailable. Reverting the change restores the current inspector without modifying stored response or daily token logs.

## Open Questions

None block implementation. During implementation, populate the capability registry from the model and effort combinations supported by the app's current Codex model set; keep unlisted future models in the explicit unavailable state until their capabilities are added.
