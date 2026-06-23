import CoreLocation
import Foundation

@MainActor
protocol LocationServicing {
    var authorizationStatus: CLAuthorizationStatus { get }
    var latestSample: LocationSample? { get }
    var recentSamples: [LocationSample] { get }
    func makeSampleStream() -> AsyncStream<LocationSample>
    func startPassiveMonitoring()
    func stopPassiveMonitoring()
    func start() throws
    func stop()
    func requestAlwaysUpgrade()
    /// Tracks whether the app is in the foreground. While backgrounded and not
    /// recording a drive, the location manager drops to low-power monitoring.
    func setForegroundActive(_ isActive: Bool)
    /// Applies the background-location capability per the user's authorization tier.
    func applyBackgroundCollectionDecision(_ decision: BackgroundCollectionDecision)
}

extension LocationServicing {
    // Default no-ops so lightweight test doubles, previews, and the sim harness
    // don't have to care about power management.
    func setForegroundActive(_ isActive: Bool) {}
    func applyBackgroundCollectionDecision(_ decision: BackgroundCollectionDecision) {}
}

@MainActor
final class LocationService: NSObject, LocationServicing {
    private static let bufferedSampleRetentionSeconds: TimeInterval = 30

    private let manager: CLLocationManager
    private var continuation: AsyncStream<LocationSample>.Continuation?
    private var bufferedSamples: [LocationSample] = []
    private var isPassiveMonitoringActive = false
    private var isCollectionActive = false
    private var isForegroundActive = false
    private var isUpdatingLocation = false

    init(manager: CLLocationManager = CLLocationManager()) {
        self.manager = manager
        super.init()
        manager.delegate = self
        manager.activityType = .automotiveNavigation
        // Background updates are opt-in per authorization tier (see
        // applyBackgroundCollectionDecision); enabling them unconditionally here is
        // what let "passive" GPS run at full power 24/7.
        manager.allowsBackgroundLocationUpdates = false
        manager.desiredAccuracy = kCLLocationAccuracyNearestTenMeters
        manager.distanceFilter = 5
        manager.pausesLocationUpdatesAutomatically = false
    }

    var authorizationStatus: CLAuthorizationStatus {
        manager.authorizationStatus
    }

    var latestSample: LocationSample? {
        prunedBufferedSamples(referenceTime: Date().timeIntervalSince1970).last
    }

    var recentSamples: [LocationSample] {
        prunedBufferedSamples(referenceTime: Date().timeIntervalSince1970)
    }

    /// Returns a fresh sample stream, finishing any previously vended one.
    /// Streams are single-use: cancelling the consuming task terminates the
    /// stream permanently, so each monitoring session must consume its own.
    func makeSampleStream() -> AsyncStream<LocationSample> {
        continuation?.finish()
        let (stream, continuation) = AsyncStream.makeStream(of: LocationSample.self)
        self.continuation = continuation
        return stream
    }

    func start() throws {
        isCollectionActive = true
        applyLocationUpdateState()
    }

    func stop() {
        isCollectionActive = false
        applyLocationUpdateState()
    }

    func startPassiveMonitoring() {
        isPassiveMonitoringActive = true
        if CLLocationManager.significantLocationChangeMonitoringAvailable() {
            manager.startMonitoringSignificantLocationChanges()
        }

        applyLocationUpdateState()
    }

    func stopPassiveMonitoring() {
        isPassiveMonitoringActive = false
        if CLLocationManager.significantLocationChangeMonitoringAvailable() {
            manager.stopMonitoringSignificantLocationChanges()
        }

        applyLocationUpdateState()
    }

    func requestAlwaysUpgrade() {
        manager.requestAlwaysAuthorization()
    }

    func setForegroundActive(_ isActive: Bool) {
        guard isForegroundActive != isActive else {
            return
        }
        isForegroundActive = isActive
        applyLocationUpdateState()
    }

    func applyBackgroundCollectionDecision(_ decision: BackgroundCollectionDecision) {
        manager.allowsBackgroundLocationUpdates = decision.shouldEnableBackgroundLocation
    }

    private func applyLocationUpdateState() {
        let decision = LocationActivationPolicy.decide(
            isPassiveMonitoring: isPassiveMonitoringActive,
            isCollecting: isCollectionActive,
            isForeground: isForegroundActive
        )

        guard decision.usesContinuousUpdates != isUpdatingLocation else {
            return
        }

        if decision.usesContinuousUpdates {
            manager.startUpdatingLocation()
        } else {
            manager.stopUpdatingLocation()
        }
        isUpdatingLocation = decision.usesContinuousUpdates
    }
}

extension LocationService: @preconcurrency CLLocationManagerDelegate {
    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        for location in locations where location.horizontalAccuracy >= 0 {
            let speedKmh = max(location.speed, 0) * 3.6
            let heading = location.course >= 0 ? location.course : 0
            let sample = LocationSample(
                timestamp: location.timestamp.timeIntervalSince1970,
                latitude: location.coordinate.latitude,
                longitude: location.coordinate.longitude,
                horizontalAccuracyMeters: location.horizontalAccuracy,
                speedKmh: speedKmh,
                headingDegrees: heading
            )
            bufferedSamples.append(sample)
            bufferedSamples = prunedBufferedSamples(referenceTime: sample.timestamp)
            continuation?.yield(sample)
        }
    }

    private func prunedBufferedSamples(referenceTime: TimeInterval) -> [LocationSample] {
        bufferedSamples.filter { referenceTime - $0.timestamp <= Self.bufferedSampleRetentionSeconds }
    }
}
