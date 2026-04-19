import Foundation
import Observation

@MainActor
@Observable
final class AppModel {
    let config: AppConfig
    let privacyZoneStore: PrivacyZoneStoring

    private let permissions: PermissionManaging
    private let defaults: UserDefaults
    private let privacyZoneDecisionKey = "ca.roadsense.ios.privacy-zone-decision"
    private let uploadQueueStore: UploadQueueStore
    private let uploader: Uploader

    private(set) var snapshot: PermissionSnapshot
    private(set) var isRequestingPermissions = false
    private(set) var pendingUploadCount = 0

    init(
        container: AppContainer,
        defaults: UserDefaults = .standard
    ) {
        self.config = container.config
        self.permissions = container.permissions
        self.defaults = defaults
        self.privacyZoneStore = container.privacyZoneStore
        self.uploadQueueStore = container.uploadQueueStore
        self.uploader = container.uploader

        let privacyZones = Self.resolvePrivacyZoneState(
            defaults: defaults,
            key: privacyZoneDecisionKey,
            privacyZoneStore: container.privacyZoneStore
        )
        self.snapshot = container.permissions.currentSnapshot(privacyZones: privacyZones)
        self.pendingUploadCount = (try? container.uploadQueueStore.pendingReadingCount()) ?? 0
    }

    var readiness: CollectionReadiness {
        CollectionReadiness.evaluate(snapshot)
    }

    var privacyZoneDecision: PrivacyZoneSetupState {
        snapshot.privacyZones
    }

    func refreshPermissions() {
        snapshot = permissions.currentSnapshot(privacyZones: resolvedPrivacyZoneState())
        refreshPendingUploadCount()
    }

    func requestInitialPermissions() async {
        guard !isRequestingPermissions else {
            return
        }

        isRequestingPermissions = true
        defer { isRequestingPermissions = false }

        snapshot = await permissions.requestInitialPermissions(privacyZones: resolvedPrivacyZoneState())
        refreshPendingUploadCount()
    }

    func refreshPrivacyZones() {
        let state = resolvedPrivacyZoneState()
        defaults.set(state.rawValue, forKey: privacyZoneDecisionKey)
        snapshot = permissions.currentSnapshot(privacyZones: state)
    }

    func skipPrivacyZonesForNow() {
        updatePrivacyZoneDecision(.skippedWithWarning)
    }

    func uploadPendingData() async {
        await uploader.drainOnce()
        refreshPendingUploadCount()
    }

    private func updatePrivacyZoneDecision(_ state: PrivacyZoneSetupState) {
        defaults.set(state.rawValue, forKey: privacyZoneDecisionKey)
        snapshot = permissions.currentSnapshot(privacyZones: state)
    }

    private func refreshPendingUploadCount() {
        pendingUploadCount = (try? uploadQueueStore.pendingReadingCount()) ?? 0
    }

    private func resolvedPrivacyZoneState() -> PrivacyZoneSetupState {
        Self.resolvePrivacyZoneState(
            defaults: defaults,
            key: privacyZoneDecisionKey,
            privacyZoneStore: privacyZoneStore
        )
    }

    private static func resolvePrivacyZoneState(
        defaults: UserDefaults,
        key: String,
        privacyZoneStore: PrivacyZoneStoring
    ) -> PrivacyZoneSetupState {
        if (try? privacyZoneStore.hasConfiguredZones()) == true {
            return .configured
        }

        guard let rawValue = defaults.string(forKey: key),
              let state = PrivacyZoneSetupState(rawValue: rawValue) else {
            return .pending
        }

        return state
    }
}
