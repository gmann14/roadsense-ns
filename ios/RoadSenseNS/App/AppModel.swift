import CoreLocation
import Foundation
import Observation

@MainActor
@Observable
final class AppModel {
    let config: AppConfig
    let privacyZoneStore: PrivacyZoneStoring
    let userStatsStore: UserStatsStore

    private let permissions: PermissionManaging
    private let locationService: LocationServicing
    private let defaults: UserDefaults
    private let privacyZoneDecisionKey = "ca.roadsense.ios.privacy-zone-decision"
    private let apiClient: APIClient
    private let readingStore: ReadingStore
    private let uploadQueueStore: UploadQueueStore
    private let uploader: Uploader
    private let sensorCoordinator: SensorCoordinator

    private(set) var snapshot: PermissionSnapshot
    private(set) var isRequestingPermissions = false
    private(set) var isPassiveMonitoringEnabled = false
    private(set) var pendingUploadCount = 0
    private(set) var acceptedReadingCount = 0
    private(set) var privacyFilteredCount = 0
    private(set) var pendingDriveCoordinates: [CLLocationCoordinate2D] = []
    private(set) var userStatsSummary = UserStatsSummary.zero

    init(
        container: AppContainer,
        defaults: UserDefaults = .standard
    ) {
        self.config = container.config
        self.permissions = container.permissions
        self.locationService = container.locationService
        self.defaults = defaults
        self.privacyZoneStore = container.privacyZoneStore
        self.apiClient = container.apiClient
        self.readingStore = container.readingStore
        self.userStatsStore = container.userStatsStore
        self.uploadQueueStore = container.uploadQueueStore
        self.uploader = container.uploader
        self.sensorCoordinator = container.sensorCoordinator

        let privacyZones = Self.resolvePrivacyZoneState(
            defaults: defaults,
            key: privacyZoneDecisionKey,
            privacyZoneStore: container.privacyZoneStore
        )
        self.snapshot = container.permissions.currentSnapshot(privacyZones: privacyZones)
        self.pendingUploadCount = (try? container.uploadQueueStore.pendingReadingCount()) ?? 0
        self.acceptedReadingCount = (try? container.readingStore.acceptedReadingCount()) ?? 0
        self.privacyFilteredCount = (try? container.readingStore.privacyFilteredReadingCount()) ?? 0
        self.pendingDriveCoordinates = (try? container.readingStore.pendingUploadCoordinates()) ?? []
        self.userStatsSummary = (try? container.userStatsStore.summary()) ?? .zero
    }

    var readiness: CollectionReadiness {
        CollectionReadiness.evaluate(snapshot)
    }

    var privacyZoneDecision: PrivacyZoneSetupState {
        snapshot.privacyZones
    }

    func refreshPermissions() {
        snapshot = permissions.currentSnapshot(privacyZones: resolvedPrivacyZoneState())
        refreshCollectionStats()
    }

    func requestInitialPermissions() async {
        guard !isRequestingPermissions else {
            return
        }

        isRequestingPermissions = true
        defer { isRequestingPermissions = false }

        snapshot = await permissions.requestInitialPermissions(privacyZones: resolvedPrivacyZoneState())
        refreshCollectionStats()
    }

    func refreshPrivacyZones() {
        let state = resolvedPrivacyZoneState()
        defaults.set(state.rawValue, forKey: privacyZoneDecisionKey)
        snapshot = permissions.currentSnapshot(privacyZones: state)
        sensorCoordinator.refreshPrivacyZones()
        refreshCollectionStats()
    }

    func skipPrivacyZonesForNow() {
        updatePrivacyZoneDecision(.skippedWithWarning)
    }

    func uploadPendingData() async {
        await uploader.drainOnce()
        refreshCollectionStats()
    }

    func startPassiveMonitoring() {
        guard readiness.canStartPassiveCollection else {
            return
        }

        sensorCoordinator.startMonitoring()
        isPassiveMonitoringEnabled = sensorCoordinator.monitoringState.isMonitoring
    }

    func stopPassiveMonitoring() {
        sensorCoordinator.stopMonitoring()
        isPassiveMonitoringEnabled = false
        refreshCollectionStats()
    }

    func requestAlwaysLocationUpgrade() {
        locationService.requestAlwaysUpgrade()
        refreshPermissions()
    }

    func deleteLocalContributionData() throws {
        try readingStore.deleteAllContributionData()
        refreshCollectionStats()
    }

    func statsSummary() throws -> UserStatsSummary {
        try userStatsStore.summary()
    }

    func fetchSegmentDetail(id: UUID) async throws -> SegmentDetailResponse {
        try await apiClient.fetchSegmentDetail(id: id)
    }

    private func updatePrivacyZoneDecision(_ state: PrivacyZoneSetupState) {
        defaults.set(state.rawValue, forKey: privacyZoneDecisionKey)
        snapshot = permissions.currentSnapshot(privacyZones: state)
    }

    private func refreshCollectionStats() {
        pendingUploadCount = (try? uploadQueueStore.pendingReadingCount()) ?? 0
        acceptedReadingCount = (try? readingStore.acceptedReadingCount()) ?? 0
        privacyFilteredCount = (try? readingStore.privacyFilteredReadingCount()) ?? 0
        pendingDriveCoordinates = (try? readingStore.pendingUploadCoordinates()) ?? []
        userStatsSummary = (try? userStatsStore.summary()) ?? .zero
        isPassiveMonitoringEnabled = sensorCoordinator.monitoringState.isMonitoring
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
