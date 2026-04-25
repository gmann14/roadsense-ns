# ADR 0001 — Driving redesign rollback strategy

**Status:** Accepted
**Date:** 2026-04-25
**Driver:** §13.8 of `docs/reviews/2026-04-24-design-audit.md`

## Context

The driving-screen redesign (§7.D1) replaces the current `MapScreen` bottom card with a 3-FAB row, ambient ring, undo chip, and several supporting components. The change is structural and affects the most-used screen in the app. We need a rollback path in case real-world usage surfaces a regression after the redesign ships.

Two rollback mechanisms were considered:

- **Runtime remote-config flag** (Supabase config table or third-party service like LaunchDarkly).
- **Compile-time flag in `AppConfig`**, with rollback via shipping a new binary.

## Decision

Ship the redesign behind a **compile-time** feature flag in `AppConfig.swift`:

```swift
struct AppConfig {
    static let drivingRedesignEnabled: Bool = true
    // ...other config...
}
```

If a regression is found after release, ship a hotfix binary with the flag flipped to `false`. Old `MapScreen` code stays in the binary for **one full release cycle (~6 weeks)** after the redesign ships, then gets deleted.

## Consequences

### Positive
- Zero new infrastructure dependencies. No remote-config service to operate, no auth or caching to worry about.
- Trivial to test: flag-on and flag-off both exercise compiled code paths.
- Predictable: the binary the user has running matches the flag state. No surprise toggles.

### Negative
- Rollback latency is the time to ship a TestFlight build + expedited App Store review (~24–48 hours).
- All users who installed the broken release stay broken until they update — no remote kill-switch.

### Mitigations
- **Crash-rate gate before flip-to-100%.** Before flipping the redesign flag from `false` to `true` in a release, watch crash-free user rate ≥ 99.5 % through TestFlight. If lower, do not ship.
- **Schema-additive discipline (mandatory).** Any database or persistence schema change introduced during the redesign must be additive only:
  - New optional columns OK.
  - New tables OK.
  - Renaming or dropping required fields: not allowed in the same release as the redesign flip.
  - Both old and new code paths must read and write the same data shape.
- **No state divergence under flag-off.** When `drivingRedesignEnabled == false`, the app must behave exactly as the pre-redesign release. No new analytics events, no new user-visible state, no new background tasks gated behind the flag.

## Escalation criteria — when to migrate to runtime flags

Move to a runtime remote-config flag if any of the following becomes true:

1. The redesign ships and a post-launch metric (crash rate, upload success rate, retention) drops > 5 % vs. baseline.
2. We need to ship two redesigns simultaneously and roll them back independently.
3. Active user count crosses 50,000, where a 24–48 h binary-rollback window starts to matter materially.

Until then, the simplicity of compile-time flags wins.

## Deletion timeline

- **Release N:** Redesign ships with `drivingRedesignEnabled = true` by default. Flag respected in code. Old `MapScreen` retained.
- **Release N+1 through N+5:** Old `MapScreen` retained. If a rollback is required, ship a hotfix with `drivingRedesignEnabled = false`.
- **Release N+6 (~6 weeks later):** If no rollbacks have been required, delete `MapScreen.swift` and remove the `drivingRedesignEnabled` flag entirely. Tests covering only the old screen are deleted in the same PR.

## Implementation checklist

- [ ] Add `drivingRedesignEnabled: Bool = true` to `AppConfig.swift`.
- [ ] In `ContentView` (or wherever `MapScreen` is mounted), branch on the flag: `if AppConfig.drivingRedesignEnabled { NewDrivingScreen() } else { MapScreen() }`.
- [ ] Add a unit test confirming both branches compile and render without crashing.
- [ ] Document the deletion target release in `docs/release-checklist.md` (if/when that exists) or in this ADR's `Status` field.

## Notes

This ADR governs the driving-screen redesign only. Future risky changes (analytics, payment flows, etc.) should each get their own rollback ADR; the same compile-time-flag pattern is fine to reuse but the schema-additive rule and the deletion timeline are change-specific.
