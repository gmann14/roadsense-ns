import CoreLocation
import CoreMotion
import Foundation

@MainActor
protocol PermissionManaging {
    func currentSnapshot(privacyZones: PrivacyZoneSetupState) -> PermissionSnapshot
    func requestInitialPermissions(privacyZones: PrivacyZoneSetupState) async -> PermissionSnapshot
}

@MainActor
final class SystemPermissionManager: NSObject, PermissionManaging {
    private let locationManager = CLLocationManager()
    private let motionActivityManager = CMMotionActivityManager()

    private var locationAuthorizationContinuation: CheckedContinuation<CLAuthorizationStatus, Never>?

    override init() {
        super.init()
        locationManager.delegate = self
    }

    func currentSnapshot(privacyZones: PrivacyZoneSetupState) -> PermissionSnapshot {
        PermissionSnapshot(
            location: map(locationManager.authorizationStatus),
            motion: map(CMMotionActivityManager.authorizationStatus()),
            privacyZones: privacyZones
        )
    }

    func requestInitialPermissions(privacyZones: PrivacyZoneSetupState) async -> PermissionSnapshot {
        if locationManager.authorizationStatus == .notDetermined {
            _ = await requestLocationWhenInUseAuthorization()
        }

        if CMMotionActivityManager.authorizationStatus() == .notDetermined {
            await requestMotionAuthorization()
        }

        return currentSnapshot(privacyZones: privacyZones)
    }

    private func requestLocationWhenInUseAuthorization() async -> CLAuthorizationStatus {
        await withCheckedContinuation { continuation in
            locationAuthorizationContinuation = continuation
            locationManager.requestWhenInUseAuthorization()
        }
    }

    private func requestMotionAuthorization() async {
        guard CMMotionActivityManager.isActivityAvailable() else {
            return
        }

        motionActivityManager.startActivityUpdates(to: .main) { [weak self] _ in
            self?.motionActivityManager.stopActivityUpdates()
        }

        for _ in 0..<20 {
            if CMMotionActivityManager.authorizationStatus() != .notDetermined {
                break
            }

            try? await Task.sleep(for: .milliseconds(250))
        }

        motionActivityManager.stopActivityUpdates()
    }

    private func map(_ status: CLAuthorizationStatus) -> LocationPermissionState {
        switch status {
        case .notDetermined:
            return .notDetermined
        case .restricted, .denied:
            return .denied
        case .authorizedWhenInUse:
            return .whenInUse
        case .authorizedAlways:
            return .always
        @unknown default:
            return .denied
        }
    }

    private func map(_ status: CMAuthorizationStatus) -> MotionPermissionState {
        switch status {
        case .notDetermined:
            return .notDetermined
        case .restricted:
            return .restricted
        case .denied:
            return .denied
        case .authorized:
            return .authorized
        @unknown default:
            return .denied
        }
    }
}

extension SystemPermissionManager: CLLocationManagerDelegate {
    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        guard let continuation = locationAuthorizationContinuation else {
            return
        }

        let status = manager.authorizationStatus
        guard status != .notDetermined else {
            return
        }

        locationAuthorizationContinuation = nil
        continuation.resume(returning: status)
    }
}
