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

    /// When `true`, sensor-detected potholes (`ReadingRecord.isPothole=true`)
    /// increment `UserStats.potholesReported` and are counted by
    /// `reconcileManualReportStats`. When `false`, only manual marks count
    /// toward the user-facing "Potholes flagged" stat.
    ///
    /// **Default false for v1.** A 2026-05-01 calibration pass against 48
    /// real manual marks + 16 sensor hits showed the two signals are
    /// near-disjoint: users mark visual potholes seen ahead at highway
    /// speeds (median 93 km/h, RMS 0.09 g at the tap moment), while the
    /// sensor only fires when the wheel hits a real impact. Both signals
    /// are valuable for server-side road-quality aggregation, but mixing
    /// them in the user-facing count surprises users — they expect
    /// "potholes I reported," not "potholes I reported plus ones the
    /// wheel hit."
    ///
    /// Sensor data is still collected and uploaded; this flag only gates
    /// whether sensor hits flow into the per-user count.
    ///
    /// Owner: design audit §11 / TestFlight calibration follow-up.
    /// Flip to `true` once a multi-driver calibration validates the
    /// detector against ground truth across vehicle types.
    static let countSensorPotholesInUserStats: Bool = false
}
