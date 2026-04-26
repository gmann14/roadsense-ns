import CoreLocation
import Foundation

@MainActor
protocol LocationServicing {
    var samples: AsyncStream<LocationSample> { get }
    var authorizationStatus: CLAuthorizationStatus { get }
    var latestSample: LocationSample? { get }
    var recentSamples: [LocationSample] { get }
    func startPassiveMonitoring()
    func stopPassiveMonitoring()
    func start() throws
    func stop()
    func requestAlwaysUpgrade()
}

@MainActor
final class LocationService: NSObject, LocationServicing {
    private static let bufferedSampleRetentionSeconds: TimeInterval = 30

    private let manager: CLLocationManager
    private let continuation: AsyncStream<LocationSample>.Continuation
    private var bufferedSamples: [LocationSample] = []
    private var isPassiveMonitoringActive = false
    private var isCollectionActive = false
    private var isUpdatingLocation = false
    let samples: AsyncStream<LocationSample>

    init(manager: CLLocationManager = CLLocationManager()) {
        self.manager = manager
        var captured: AsyncStream<LocationSample>.Continuation?
        self.samples = AsyncStream<LocationSample> { continuation in
            captured = continuation
        }
        self.continuation = captured!
        super.init()
        manager.delegate = self
        manager.activityType = .automotiveNavigation
        manager.allowsBackgroundLocationUpdates = true
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

    private func applyLocationUpdateState() {
        let shouldUpdateLocation = isPassiveMonitoringActive || isCollectionActive
        guard shouldUpdateLocation != isUpdatingLocation else {
            return
        }

        if shouldUpdateLocation {
            manager.startUpdatingLocation()
        } else {
            manager.stopUpdatingLocation()
        }
        isUpdatingLocation = shouldUpdateLocation
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
            continuation.yield(sample)
        }
    }

    private func prunedBufferedSamples(referenceTime: TimeInterval) -> [LocationSample] {
        bufferedSamples.filter { referenceTime - $0.timestamp <= Self.bufferedSampleRetentionSeconds }
    }
}
