import Foundation

/// Which location-manager update modes should be active for a given collection state.
///
/// `usesContinuousUpdates` maps to `startUpdatingLocation()` — the high-accuracy,
/// high-power GPS stream. `usesSignificantLocationChanges` maps to
/// `startMonitoringSignificantLocationChanges()` — the low-power, cell/Wi-Fi based
/// stream that also relaunches the app in the background when the user moves.
public struct LocationActivationDecision: Equatable, Sendable {
    public let usesContinuousUpdates: Bool
    public let usesSignificantLocationChanges: Bool

    public init(usesContinuousUpdates: Bool, usesSignificantLocationChanges: Bool) {
        self.usesContinuousUpdates = usesContinuousUpdates
        self.usesSignificantLocationChanges = usesSignificantLocationChanges
    }
}

/// Decides how aggressively the location manager should run.
///
/// The collector has two tiers:
///   - **Passive standby:** detect that a drive has started. This must be cheap,
///     because it can be active all day while the user walks, sits, or sleeps.
///   - **Active collection:** record road-quality readings during an actual drive.
///     High-accuracy continuous GPS is justified here because the session is bounded.
///
/// Continuous GPS is therefore only enabled when (a) a drive is being recorded, or
/// (b) the app is in the foreground, where the user can see the map/puck and may file
/// a manual pothole report that needs a fresh fix. While the app is backgrounded and
/// no drive is in progress, only significant-location-change monitoring runs — which
/// is the all-day-in-pocket case that previously drained the battery by holding the
/// GPS chip at full power 24/7.
public enum LocationActivationPolicy {
    public static func decide(
        isPassiveMonitoring: Bool,
        isCollecting: Bool,
        isForeground: Bool
    ) -> LocationActivationDecision {
        let usesContinuousUpdates = isCollecting || (isPassiveMonitoring && isForeground)
        let usesSignificantLocationChanges = isPassiveMonitoring
        return LocationActivationDecision(
            usesContinuousUpdates: usesContinuousUpdates,
            usesSignificantLocationChanges: usesSignificantLocationChanges
        )
    }
}
