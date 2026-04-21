import CoreLocation
import Foundation

@MainActor
protocol LocationServicing {
    var samples: AsyncStream<LocationSample> { get }
    var authorizationStatus: CLAuthorizationStatus { get }
    var latestSample: LocationSample? { get }
    var recentSamples: [LocationSample] { get }
    func start() throws
    func stop()
    func requestAlwaysUpgrade()
}

@MainActor
final class LocationService: NSObject, LocationServicing {
    private let manager: CLLocationManager
    private let continuation: AsyncStream<LocationSample>.Continuation
    private var bufferedSamples: [LocationSample] = []
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
        manager.startUpdatingLocation()
    }

    func stop() {
        manager.stopUpdatingLocation()
    }

    func requestAlwaysUpgrade() {
        manager.requestAlwaysAuthorization()
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
        bufferedSamples.filter { referenceTime - $0.timestamp <= 3.5 }
    }
}
