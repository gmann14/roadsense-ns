import Foundation

/// Compile-time feature flags. Distinct from `AppConfig`, which holds
/// environment-loaded runtime settings (API URLs, tokens, etc.).
///
/// Each flag has a single source of truth (this file), a clear ownership
/// comment, and an ADR linking the rollback plan. Flip the flag here and
/// ship a binary — that's the rollback procedure for the v1 ADR.
///
/// References:
/// - `docs/adr/0001-driving-redesign-rollback.md`
/// - `docs/reviews/2026-04-24-design-audit.md` §13.8
enum FeatureFlags {

    /// When `true`, `ContentView` mounts the redesigned driving screen
    /// (`MapScreenRedesign`). When `false`, the legacy `MapScreen` is mounted
    /// — used for emergency rollback within a release cycle.
    ///
    /// Owner: design audit §7.D1 / §13.2 / §13.3.
    /// Deletion target: 6 weeks after the redesign ships with no rollbacks.
    static let drivingRedesignEnabled: Bool = true
}
