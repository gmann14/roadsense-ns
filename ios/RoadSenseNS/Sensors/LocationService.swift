import CoreLocation
import Foundation

@MainActor
protocol LocationServicing {
    var samples: AsyncStream<LocationSample> { get }
    var authorizationStatus: CLAuthorizationStatus { get }
    func start() throws
    func stop()
    func requestAlwaysUpgrade()
}

@MainActor
final class LocationService: NSObject, LocationServicing {
    private let manager: CLLocationManager
    private let continuation: AsyncStream<LocationSample>.Continuation
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

extension LocationService: CLLocationManagerDelegate {
    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        for location in locations where location.horizontalAccuracy >= 0 {
            let speedKmh = max(location.speed, 0) * 3.6
            let heading = location.course >= 0 ? location.course : 0
            continuation.yield(
                LocationSample(
                    timestamp: location.timestamp.timeIntervalSince1970,
                    latitude: location.coordinate.latitude,
                    longitude: location.coordinate.longitude,
                    horizontalAccuracyMeters: location.horizontalAccuracy,
                    speedKmh: speedKmh,
                    headingDegrees: heading
                )
            )
        }
    }
}
