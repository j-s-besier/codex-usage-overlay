## Why

The counter currently keeps only a daily total, which cannot show how usage differs by model or reasoning effort. Persisting response-level usage metadata will make those comparisons possible and give the existing log inspector a useful detailed history.

## What Changes

- Read each completed response's token usage from local Codex session JSONL files and append one corresponding metadata-only record to an app-owned JSONL log.
- Record response and turn identifiers, session/thread identifiers, timestamp, model, reasoning effort, and the available input, cached-input, cache-write, output, reasoning-output, and total token counts.
- Keep the log recoverable and idempotent across app restarts so a response is not recorded twice.
- Make the response log inspectable and groupable by model and reasoning effort.
- Do not include conversation text or attempt to attribute tokens to account quota or limit usage.

## Capabilities

### New Capabilities
- `response-token-usage-log`: Local durable logging and inspection of token usage per Codex model response, including model and reasoning-effort dimensions.

### Modified Capabilities

## Impact

- `LocalTokenUsageCounter.swift` will parse response usage records and coordinate durable writes under the configured Codex home directory.
- `CodexUsageOverlayApp.swift` will expose inspection of the response-level log.
- The app-owned usage log will be stored locally as JSONL. No network service, external dependency, message content, or quota data is required.
