import Foundation

/// Driver-distraction gates (App Review guideline 1.4.5).
///
/// - Marking a pothole by tap while the vehicle is moving needs a one-tap
///   "are you a passenger?" confirmation; drivers are pointed at the
///   hands-free Siri / Shortcuts intent instead.
/// - Photo capture is blocked outright above walking speed.
///
/// Speeds come from CoreLocation. An invalid or missing speed is treated as
/// unknown, not as moving: every capture path still requires a fresh GPS fix,
/// and an unknown speed almost always means the phone is stationary or the
/// fix is poor.
public enum DriverSafetyPolicy {
    /// Above this speed a manual pothole tap asks for passenger confirmation.
    public static let manualMarkConfirmationSpeedKmh: Double = 10

    /// Above this speed the camera is blocked (walking pace is ~5 km/h).
    public static let maxPhotoCaptureSpeedKmh: Double = 8

    public static func manualMarkRequiresPassengerConfirmation(speedKmh: Double?) -> Bool {
        guard let speedKmh, speedKmh.isFinite, speedKmh >= 0 else {
            return false
        }
        return speedKmh > manualMarkConfirmationSpeedKmh
    }

    public static func isPhotoCaptureAllowed(speedKmh: Double?) -> Bool {
        guard let speedKmh, speedKmh.isFinite, speedKmh >= 0 else {
            return true
        }
        return speedKmh <= maxPhotoCaptureSpeedKmh
    }
}
