## Context

The app refreshes the locally collected daily token total every 30 seconds. The value is rendered in an AppKit status item and in a SwiftUI popover. Both currently read the source value directly, so updates appear as a sudden jump. The existing token counter and CSV persistence remain the source of truth.

## Goals / Non-Goals

**Goals:**
- Interpolate displayed daily totals over a quarter second in both views.
- Start the first value immediately and avoid carrying yesterday's count into a new local day.
- Honor the system Reduce Motion setting.

**Non-Goals:**
- Change collection, persistence, refresh cadence, or usage-limit calculations.
- Animate percentage values or other UI values.

## Decisions

- Keep `dailyTokens` as the collected source value and add a separate published display value. This avoids changing token logging or API inputs while allowing both views to share the same animation state.
- Run a cancellable main-actor task at roughly 30 frames per second for a quarter second, interpolating from the currently displayed integer to the newest target. A retarget begins at the current visible number so successive refreshes do not jump backward to an earlier animation start.
- Associate each refresh result with the local calendar day on which its token total was read. The first total and a changed day are applied immediately; same-day changes animate.
- Read `NSWorkspace.shared.accessibilityDisplayShouldReduceMotion` when applying and while advancing animation frames. If enabled, cancel interpolation and show the target. Apple documents this AppKit property and its accessibility-options change notification: [NSWorkspace Reduce Motion](https://developer.apple.com/documentation/appkit/nsworkspace/accessibilitydisplayshouldreducemotion).
- Render the shared display value in both views while leaving limit percentages and token formatting unchanged.

## Risks / Trade-offs

- [Frequent SwiftUI and status-item updates may create unnecessary work] → Limit updates to approximately 30 frames per second and stop the task at completion or retarget.
- [A refresh crossing local midnight could associate a count with the wrong day] → Capture the day alongside the locally read total before the asynchronous fetch proceeds.
- [Reduce Motion may change during an animation] → Check the system preference during each animation step and snap to the target when it becomes enabled.

## Migration Plan

No data migration is needed. The displayed value is transient UI state; persisted daily totals and response logs are unchanged. Reverting the code removes the interpolation without affecting stored data.

## Open Questions

None.
