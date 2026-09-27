## ADDED Requirements

### Requirement: Animate refreshed daily token totals
The application MUST animate a changed daily token total from its currently displayed value to the newly collected value over a quarter second in both the menu bar and usage popover.

#### Scenario: Daily total changes after collection
- **WHEN** a refresh reports a new daily total during the same local calendar day
- **THEN** the menu bar and popover display values that progress from the current value to the new total over a quarter second

#### Scenario: Animation is retargeted during an active animation
- **WHEN** a new total arrives before the current one-second animation finishes
- **THEN** the display continues from its currently displayed value toward the newest total over a quarter second

### Requirement: Handle initial and new-day totals immediately
The application MUST display the first available daily total immediately and MUST apply a new local day's total immediately without interpolating from the previous day's value.

#### Scenario: First total becomes available
- **WHEN** the application receives its first daily total after launch
- **THEN** both displays show that total without an animation from zero

#### Scenario: Local day changes
- **WHEN** a refresh reports a total for a different local calendar day
- **THEN** both displays immediately show the new day's total

### Requirement: Respect Reduce Motion
The application MUST immediately display a refreshed total when macOS Reduce Motion is enabled.

#### Scenario: Reduce Motion is enabled during a refresh
- **WHEN** a new daily total is received while Reduce Motion is enabled
- **THEN** both displays show the new total immediately

#### Scenario: Reduce Motion is enabled during an animation
- **WHEN** macOS Reduce Motion becomes enabled while the total is animating
- **THEN** the animation stops and both displays show the animation's target value

### Requirement: Preserve token display formats and other usage values
The application MUST retain the existing compact menu bar number format and full popover number format, and MUST NOT animate limit percentages or change token collection and persistence behavior.

#### Scenario: Total is rendered in both locations
- **WHEN** a daily total is displayed
- **THEN** the menu bar uses the compact format and the popover uses the full localized number format

#### Scenario: Limit percentage refreshes
- **WHEN** a usage limit percentage changes
- **THEN** it updates without using the daily token count animation
