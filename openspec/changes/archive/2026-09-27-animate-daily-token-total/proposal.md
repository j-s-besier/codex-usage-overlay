## Why

The menu bar token total changes abruptly on each refresh, even though the value normally increases gradually during work. A short count animation will make those updates easier to notice and more pleasant to follow.

## What Changes

- Animate the daily token total in the menu bar and usage popover toward each refreshed value over a quarter second.
- Preserve the existing compact menu bar format and full popover number format.
- Show the first loaded value immediately, and reset immediately when the local day changes.
- Respect macOS Reduce Motion by updating the displayed value without animation.
- Keep token collection, refresh cadence, limit percentages, and usage logs unchanged.

## Capabilities

### New Capabilities

- `daily-token-counter-display`: Defines how daily token totals update visually in the menu bar and popover.

### Modified Capabilities

None.

## Impact

- `Sources/CodexUsageOverlay/CodexUsageOverlayApp.swift`: animate the displayed token value while retaining the fetched value as the source of truth.
- `Sources/CodexUsageOverlay/LocalTokenUsageCounter.swift`: reuse the current compact formatting without changing collection or persistence.
- macOS accessibility behavior: avoid announcing every intermediate animation frame and honor Reduce Motion.
