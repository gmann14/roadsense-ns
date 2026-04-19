import Foundation
import Observation

@MainActor
@Observable
final class AppModel {
    let config: AppConfig

    private let permissions: PermissionManaging
    private let defaults: UserDefaults
    private let privacyZoneDecisionKey = "ca.roadsense.ios.privacy-zone-decision"

    private(set) var snapshot: PermissionSnapshot
    private(set) var isRequestingPermissions = false

    init(
        container: AppContainer,
        defaults: UserDefaults = .standard
    ) {
        self.config = container.config
        self.permissions = container.permissions
        self.defaults = defaults

        let privacyZones = Self.loadPrivacyZoneState(from: defaults, key: privacyZoneDecisionKey)
        self.snapshot = container.permissions.currentSnapshot(privacyZones: privacyZones)
    }

    var readiness: CollectionReadiness {
        CollectionReadiness.evaluate(snapshot)
    }

    var privacyZoneDecision: PrivacyZoneSetupState {
        snapshot.privacyZones
    }

    func refreshPermissions() {
        snapshot = permissions.currentSnapshot(privacyZones: privacyZoneDecision)
    }

    func requestInitialPermissions() async {
        guard !isRequestingPermissions else {
            return
        }

        isRequestingPermissions = true
        defer { isRequestingPermissions = false }

        snapshot = await permissions.requestInitialPermissions(privacyZones: privacyZoneDecision)
    }

    func markPrivacyZonesConfigured() {
        updatePrivacyZoneDecision(.configured)
    }

    func skipPrivacyZonesForNow() {
        updatePrivacyZoneDecision(.skippedWithWarning)
    }

    private func updatePrivacyZoneDecision(_ state: PrivacyZoneSetupState) {
        defaults.set(state.rawValue, forKey: privacyZoneDecisionKey)
        snapshot = permissions.currentSnapshot(privacyZones: state)
    }

    private static func loadPrivacyZoneState(from defaults: UserDefaults, key: String) -> PrivacyZoneSetupState {
        guard let rawValue = defaults.string(forKey: key),
              let state = PrivacyZoneSetupState(rawValue: rawValue) else {
            return .pending
        }

        return state
    }
}
