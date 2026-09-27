## 1. Add inspector presentation data

- [x] 1.1 Add a centralized per-model reasoning-effort capability registry with stable model keys, display names, effort ordering, and safe behavior for unlisted models.
- [x] 1.2 Add testable presentation grouping for model, session, and thread summaries while keeping aggregates based on per-response usage only.
- [x] 1.3 Add a defensive local session-index reader that maps only `id` and `thread_name` from `session_index.jsonl` and falls back when metadata is unavailable.

## 2. Implement the response and model views

- [x] 2.1 Replace the current model/effort-only inspector with Responses, Model, and Session grouping controls while preserving the selected local-day picker and empty state.
- [x] 2.2 Build the raw response list with newest-first ordering, prominent input/output/total metrics, and an expansion for every remaining token dimension and identifiers.
- [x] 2.3 Build the compact Model list with one expandable row per model, aggregate total tokens, and supported-effort rows including zeroes and an Unknown row.

## 3. Implement nested session browsing

- [x] 3.1 Build session groups with local session names, stable ID fallback, response totals, and response/thread counts.
- [x] 3.2 Make sessions expand into threads and threads expand into response rows with the response details interaction.

## 4. Verify the inspector

- [x] 4.1 Add Core tests for capability ordering, zero-filled supported efforts, unlisted models, unknown efforts, session-index mapping, and session-index fallback.
- [x] 4.2 Add or update grouping tests for day filtering, newest-first ordering, nested session/thread membership, and non-double-counted totals.
- [x] 4.3 Prepare and reuse day-scoped presentation snapshots off the main UI actor so grouping changes and expansions do not repeat full-log processing.
- [ ] 4.4 Build and run the test suite, then manually verify all three views, list placement, expansions, token colors, and empty-day behavior in the macOS app.
