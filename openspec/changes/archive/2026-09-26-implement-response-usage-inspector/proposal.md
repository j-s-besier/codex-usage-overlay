## Why

The app records response-level token usage locally, but its current inspector only presents model-and-effort disclosure rows. The approved HTML preview establishes a clearer way to inspect the same local data by response, model, or session, so the native app should provide those views.

## What Changes

- Replace the current inspector layout with the approved preview's Responses, Model, and Session grouping modes while retaining the selected local-day picker.
- Show raw responses newest first, with input, output, and total tokens prominent and the remaining token dimensions available through an expansion.
- Show one compact list row per model with aggregate total tokens and an expansion containing input, output, and total counts for every supported reasoning effort, including zeroes for supported efforts without responses.
- Show sessions by their local Codex session names, then expand each session into threads and response entries.
- Keep response and session totals derived from per-response usage; do not double-count cached-input or reasoning-output breakdowns.
- Keep all inspection local and metadata-only. Do not change token collection, quota reporting, or the existing response-log format.

## Capabilities

### New Capabilities

### Modified Capabilities
- `response-token-usage-log`: Expand the inspector's grouping modes and specify response, model-row, effort, and session/thread presentation.

## Impact

- `Sources/CodexUsageOverlay/CodexUsageOverlayApp.swift`: replace the current inspector presentation and add local session-name lookup.
- `Sources/CodexUsageCore/ResponseUsageLogStore.swift` or a focused Core helper: expose presentation grouping and a local model-to-effort capability map without changing the persisted response record schema.
- `Tests/CodexUsageCoreTests`: verify effort ordering, zero-filled supported efforts, grouping totals, and parsing of session names.
- The local `session_index.jsonl` is read for `id` and `thread_name` only. No network requests, new dependencies, prompt text, or assistant/tool content are required.
