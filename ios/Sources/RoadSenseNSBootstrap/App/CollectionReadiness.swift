import Foundation

public enum LocationPermissionState: String, Codable, CaseIterable, Sendable {
    case notDetermined
    case denied
    case whenInUse
    case always

    public var displayName: String {
        switch self {
        case .notDetermined:
            return "Not determined"
        case .denied:
            return "Denied"
        case .whenInUse:
            return "When In Use"
        case .always:
            return "Always"
        }
    }
}

public enum MotionPermissionState: String, Codable, CaseIterable, Sendable {
    case notDetermined
    case denied
    case restricted
    case authorized

    public var displayName: String {
        switch self {
        case .notDetermined:
            return "Not determined"
        case .denied:
            return "Denied"
        case .restricted:
            return "Restricted"
        case .authorized:
            return "Authorized"
        }
    }
}

public enum PrivacyZoneSetupState: String, Codable, CaseIterable, Sendable {
    case pending
    case configured
    case skippedWithWarning
}

public struct PermissionSnapshot: Equatable, Sendable {
    public let location: LocationPermissionState
    public let motion: MotionPermissionState
    public let privacyZones: PrivacyZoneSetupState

    public init(
        location: LocationPermissionState,
        motion: MotionPermissionState,
        privacyZones: PrivacyZoneSetupState
    ) {
        self.location = location
        self.motion = motion
        self.privacyZones = privacyZones
    }
}

public enum CollectionReadinessStage: Equatable, Sendable {
    case permissionsRequired
    case permissionHelp
    case ready
}

public enum BackgroundCollectionState: Equatable, Sendable {
    case unavailable
    case upgradeRequired
    case enabled

    public var displayName: String {
        switch self {
        case .unavailable:
            return "Unavailable"
        case .upgradeRequired:
            return "Needs Always Location"
        case .enabled:
            return "Enabled"
        }
    }
}

public struct CollectionReadiness: Equatable, Sendable {
    public let stage: CollectionReadinessStage
    public let canStartPassiveCollection: Bool
    public let backgroundCollection: BackgroundCollectionState
    public let showsPrivacyRiskWarning: Bool

    public init(
        stage: CollectionReadinessStage,
        canStartPassiveCollection: Bool,
        backgroundCollection: BackgroundCollectionState,
        showsPrivacyRiskWarning: Bool
    ) {
        self.stage = stage
        self.canStartPassiveCollection = canStartPassiveCollection
        self.backgroundCollection = backgroundCollection
        self.showsPrivacyRiskWarning = showsPrivacyRiskWarning
    }

    public static func evaluate(_ snapshot: PermissionSnapshot) -> CollectionReadiness {
        guard !snapshot.location.isDeniedOrBlocked, !snapshot.motion.isDeniedOrBlocked else {
            return CollectionReadiness(
                stage: .permissionHelp,
                canStartPassiveCollection: false,
                backgroundCollection: .unavailable,
                showsPrivacyRiskWarning: snapshot.privacyZones == .skippedWithWarning
            )
        }

        guard snapshot.location != .notDetermined, snapshot.motion != .notDetermined else {
            return CollectionReadiness(
                stage: .permissionsRequired,
                canStartPassiveCollection: false,
                backgroundCollection: .unavailable,
                showsPrivacyRiskWarning: false
            )
        }

        let backgroundCollection: BackgroundCollectionState = switch snapshot.location {
        case .always:
            .enabled
        case .whenInUse:
            .upgradeRequired
        case .notDetermined, .denied:
            .unavailable
        }

        return CollectionReadiness(
            stage: .ready,
            canStartPassiveCollection: true,
            backgroundCollection: backgroundCollection,
            showsPrivacyRiskWarning: snapshot.privacyZones == .skippedWithWarning
        )
    }
}

private extension LocationPermissionState {
    var isDeniedOrBlocked: Bool {
        self == .denied
    }
}

private extension MotionPermissionState {
    var isDeniedOrBlocked: Bool {
        self == .denied || self == .restricted
    }
}
