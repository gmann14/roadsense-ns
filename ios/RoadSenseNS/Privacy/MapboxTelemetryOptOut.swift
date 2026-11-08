import Foundation

/// Turns off Mapbox's own usage and location telemetry.
///
/// Mapbox Maps SDK v11 decides whether to send telemetry events from the
/// `MGLMapboxMetricsEnabled` user default: its `EventsManager` registers it
/// with a default of `true` and observes it, and `false` disables both event
/// collection and location telemetry. Writing `false` before the first map
/// view or `MapboxOptions` use means nothing is sent at all. The app has no
/// in-app toggle to turn it back on.
enum MapboxTelemetryOptOut {
    static let metricsEnabledKey = "MGLMapboxMetricsEnabled"

    static func apply(defaults: UserDefaults = .standard) {
        defaults.set(false, forKey: metricsEnabledKey)
    }

    static func isOptedOut(defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: metricsEnabledKey) as? Bool == false
    }
}
