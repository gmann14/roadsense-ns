import Foundation

public struct BackgroundCollectionDecision: Equatable, Sendable {
    public let shouldEnableBackgroundLocation: Bool
    public let shouldRegisterSignificantLocationBootstrap: Bool
    public let shouldPromptForAlwaysUpgrade: Bool

    public init(
        shouldEnableBackgroundLocation: Bool,
        shouldRegisterSignificantLocationBootstrap: Bool,
        shouldPromptForAlwaysUpgrade: Bool
    ) {
        self.shouldEnableBackgroundLocation = shouldEnableBackgroundLocation
        self.shouldRegisterSignificantLocationBootstrap = shouldRegisterSignificantLocationBootstrap
        self.shouldPromptForAlwaysUpgrade = shouldPromptForAlwaysUpgrade
    }
}

public enum BackgroundCollectionPolicy {
    public static func evaluate(_ snapshot: PermissionSnapshot) -> BackgroundCollectionDecision {
        let readiness = CollectionReadiness.evaluate(snapshot)

        guard readiness.canStartPassiveCollection else {
            return BackgroundCollectionDecision(
                shouldEnableBackgroundLocation: false,
                shouldRegisterSignificantLocationBootstrap: false,
                shouldPromptForAlwaysUpgrade: false
            )
        }

        switch snapshot.location {
        case .always:
            return BackgroundCollectionDecision(
                shouldEnableBackgroundLocation: true,
                shouldRegisterSignificantLocationBootstrap: true,
                shouldPromptForAlwaysUpgrade: false
            )
        case .whenInUse:
            return BackgroundCollectionDecision(
                shouldEnableBackgroundLocation: false,
                shouldRegisterSignificantLocationBootstrap: false,
                shouldPromptForAlwaysUpgrade: true
            )
        case .notDetermined, .denied:
            return BackgroundCollectionDecision(
                shouldEnableBackgroundLocation: false,
                shouldRegisterSignificantLocationBootstrap: false,
                shouldPromptForAlwaysUpgrade: false
            )
        }
    }
}
