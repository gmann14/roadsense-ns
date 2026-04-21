import CoreLocation
import Foundation
import Observation

enum ManualPotholeReportResult: Equatable {
    case queued(UUID)
    case unavailableLocation
    case insidePrivacyZone
}

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
    private let collectionPausedKey = "ca.roadsense.ios.collection-paused"
    private let apiClient: APIClient
    private let potholeActionStore: PotholeActionStore
    private let readingStore: ReadingStore
    private let uploadQueueStore: UploadQueueStore
    private let uploadDrainCoordinator: UploadDrainCoordinator
    private let sensorCoordinator: SensorCoordinator
    private let logger: RoadSenseLogger
    private let potholeLocator = ManualPotholeLocator()

    private(set) var snapshot: PermissionSnapshot
    private(set) var isRequestingPermissions = false
    private(set) var isPassiveMonitoringEnabled = false
    private(set) var isCollectionPausedByUser = false
    private(set) var pendingUploadCount = 0
    private(set) var uploadStatusSummary = UploadQueueStatusSummary.empty
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
        self.potholeActionStore = container.potholeActionStore
        self.readingStore = container.readingStore
        self.userStatsStore = container.userStatsStore
        self.uploadQueueStore = container.uploadQueueStore
        self.uploadDrainCoordinator = container.uploadDrainCoordinator
        self.sensorCoordinator = container.sensorCoordinator
        self.logger = container.logger

        let privacyZones = Self.resolvePrivacyZoneState(
            defaults: defaults,
            key: privacyZoneDecisionKey,
            privacyZoneStore: container.privacyZoneStore
        )
        self.snapshot = container.permissions.currentSnapshot(privacyZones: privacyZones)
        self.pendingUploadCount = (try? container.uploadQueueStore.pendingReadingCount()) ?? 0
        self.uploadStatusSummary = (try? container.uploadQueueStore.statusSummary()) ?? .empty
        self.acceptedReadingCount = (try? container.readingStore.acceptedReadingCount()) ?? 0
        self.privacyFilteredCount = (try? container.readingStore.privacyFilteredReadingCount()) ?? 0
        self.pendingDriveCoordinates = (try? container.readingStore.pendingUploadCoordinates()) ?? []
        self.userStatsSummary = (try? container.userStatsStore.summary()) ?? .zero
        self.isCollectionPausedByUser = defaults.bool(forKey: collectionPausedKey)
        _ = try? potholeActionStore.promoteExpiredPendingUndoActions()
        syncPassiveMonitoringState()
        refreshCollectionStats()
    }

    var readiness: CollectionReadiness {
        CollectionReadiness.evaluate(snapshot)
    }

    var privacyZoneDecision: PrivacyZoneSetupState {
        snapshot.privacyZones
    }

    func refreshPermissions() {
        snapshot = resolvedPermissionSnapshot()
        syncPassiveMonitoringState()
        refreshCollectionStats()
    }

    func requestInitialPermissions() async {
        guard !isRequestingPermissions else {
            return
        }

        isRequestingPermissions = true
        defer { isRequestingPermissions = false }

        let privacyZones = resolvedPrivacyZoneState()
        _ = await permissions.requestInitialPermissions(privacyZones: privacyZones)
        snapshot = resolvedPermissionSnapshot(privacyZones: privacyZones)
        syncPassiveMonitoringState()
        refreshCollectionStats()
    }

    func refreshPrivacyZones() {
        let state = resolvedPrivacyZoneState()
        defaults.set(state.rawValue, forKey: privacyZoneDecisionKey)
        snapshot = resolvedPermissionSnapshot(privacyZones: state)
        sensorCoordinator.refreshPrivacyZones()
        syncPassiveMonitoringState()
        refreshCollectionStats()
    }

    func skipPrivacyZonesForNow() {
        updatePrivacyZoneDecision(.skippedWithWarning)
    }

    func uploadPendingData() async {
        _ = await uploadDrainCoordinator.requestDrain(reason: .diagnosticsRetry)
        refreshCollectionStats()
    }

    func retryFailedUploads() async {
        do {
            try uploadQueueStore.retryFailedBatches()
            _ = await uploadDrainCoordinator.requestDrain(reason: .diagnosticsRetry)
            refreshCollectionStats()
        } catch {
            logger.error("failed to retry failed uploads: \(error.localizedDescription)")
        }
    }

    func handleAppDidBecomeActive() async {
        refreshPermissions()
        _ = await uploadDrainCoordinator.requestDrain(reason: .foreground)
        refreshCollectionStats()
    }

    func handleAppDidEnterBackground() {
        refreshCollectionStats()
        guard pendingUploadCount >= 100 else {
            return
        }

        BackgroundTaskRegistrar.scheduleNextUploadDrain(
            earliestBegin: Date().addingTimeInterval(15 * 60),
            logger: logger
        )
    }

    func startPassiveMonitoring() {
        guard readiness.canStartPassiveCollection else {
            return
        }

        defaults.set(false, forKey: collectionPausedKey)
        isCollectionPausedByUser = false
        sensorCoordinator.startMonitoring()
        refreshCollectionStats()
    }

    func stopPassiveMonitoring() {
        defaults.set(true, forKey: collectionPausedKey)
        isCollectionPausedByUser = true
        sensorCoordinator.stopMonitoring()
        refreshCollectionStats()
    }

    func requestAlwaysLocationUpgrade() {
        locationService.requestAlwaysUpgrade()
        refreshPermissions()
        Task { @MainActor in
            for _ in 0..<10 {
                try? await Task.sleep(for: .milliseconds(250))
                refreshPermissions()

                if readiness.backgroundCollection != .upgradeRequired {
                    break
                }
            }
        }
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

    func markPothole(now: Date = Date()) -> ManualPotholeReportResult {
        do {
            try potholeActionStore.promoteExpiredPendingUndoActions(now: now)
        } catch {
            logger.error("failed to promote pending pothole actions: \(error.localizedDescription)")
        }

        let chosenSample = potholeLocator.locate(
            tapTimestamp: now,
            recentSamples: locationService.recentSamples,
            latestSample: locationService.latestSample
        )

        guard let chosenSample, hasUsableLocation(chosenSample, now: now) else {
            return .unavailableLocation
        }

        guard !isInsidePrivacyZone(chosenSample) else {
            return .insidePrivacyZone
        }

        do {
            let action = try potholeActionStore.queueManualReport(sample: chosenSample, now: now)
            logger.info("manual pothole report queued: \(action.id.uuidString)")
            schedulePendingUndoPromotion(for: action.id)
            return .queued(action.id)
        } catch {
            logger.error("failed to queue pothole report: \(error.localizedDescription)")
            return .unavailableLocation
        }
    }

    func undoPotholeReport(id: UUID) {
        do {
            try potholeActionStore.discard(id: id)
            logger.info("manual pothole report discarded: \(id.uuidString)")
        } catch {
            logger.error("failed to discard pothole report: \(error.localizedDescription)")
        }
    }

    private func updatePrivacyZoneDecision(_ state: PrivacyZoneSetupState) {
        defaults.set(state.rawValue, forKey: privacyZoneDecisionKey)
        snapshot = resolvedPermissionSnapshot(privacyZones: state)
    }

    private func refreshCollectionStats() {
        _ = try? potholeActionStore.promoteExpiredPendingUndoActions()
        pendingUploadCount = (try? uploadQueueStore.pendingReadingCount()) ?? 0
        uploadStatusSummary = (try? uploadQueueStore.statusSummary()) ?? .empty
        acceptedReadingCount = (try? readingStore.acceptedReadingCount()) ?? 0
        privacyFilteredCount = (try? readingStore.privacyFilteredReadingCount()) ?? 0
        pendingDriveCoordinates = (try? readingStore.pendingUploadCoordinates()) ?? []
        userStatsSummary = (try? userStatsStore.summary()) ?? .zero
        isCollectionPausedByUser = defaults.bool(forKey: collectionPausedKey)
        isPassiveMonitoringEnabled = sensorCoordinator.monitoringState.isMonitoring
    }

    private func hasUsableLocation(_ sample: LocationSample, now: Date) -> Bool {
        let ageSeconds = now.timeIntervalSince1970 - sample.timestamp
        return ageSeconds <= 10 && sample.horizontalAccuracyMeters <= 25
    }

    private func isInsidePrivacyZone(_ sample: LocationSample) -> Bool {
        guard let zones = try? privacyZoneStore.fetchAll(),
              !zones.isEmpty else {
            return false
        }

        let sampleLocation = CLLocation(latitude: sample.latitude, longitude: sample.longitude)
        return zones.contains { zone in
            sampleLocation.distance(
                from: CLLocation(latitude: zone.latitude, longitude: zone.longitude)
            ) < zone.radiusM
        }
    }

    private func schedulePendingUndoPromotion(for actionID: UUID) {
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(5.1))
            guard let self else { return }

            do {
                _ = try self.potholeActionStore.promoteExpiredPendingUndoActions()
                self.logger.info("manual pothole report ready for upload: \(actionID.uuidString)")
            } catch {
                self.logger.error("failed to promote pothole action after undo window: \(error.localizedDescription)")
            }
        }
    }

    private func syncPassiveMonitoringState() {
        if readiness.canStartPassiveCollection {
            guard !defaults.bool(forKey: collectionPausedKey) else {
                return
            }

            if !sensorCoordinator.monitoringState.isMonitoring {
                sensorCoordinator.startMonitoring()
            }
        } else if sensorCoordinator.monitoringState.isMonitoring {
            sensorCoordinator.stopMonitoring()
        }
    }

    private func resolvedPrivacyZoneState() -> PrivacyZoneSetupState {
        Self.resolvePrivacyZoneState(
            defaults: defaults,
            key: privacyZoneDecisionKey,
            privacyZoneStore: privacyZoneStore
        )
    }

    private func resolvedPermissionSnapshot(
        privacyZones: PrivacyZoneSetupState? = nil
    ) -> PermissionSnapshot {
        let resolvedPrivacyZones = privacyZones ?? resolvedPrivacyZoneState()
        let currentSnapshot = permissions.currentSnapshot(privacyZones: resolvedPrivacyZones)

        return PermissionSnapshot(
            location: mergedLocationState(
                currentSnapshot.location,
                with: locationService.authorizationStatus
            ),
            motion: currentSnapshot.motion,
            privacyZones: resolvedPrivacyZones
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

    private func mergedLocationState(
        _ currentState: LocationPermissionState,
        with serviceStatus: CLAuthorizationStatus
    ) -> LocationPermissionState {
        let serviceState: LocationPermissionState
        switch serviceStatus {
        case .authorizedAlways:
            serviceState = .always
        case .authorizedWhenInUse:
            serviceState = .whenInUse
        case .restricted, .denied:
            serviceState = .denied
        case .notDetermined:
            serviceState = .notDetermined
        @unknown default:
            serviceState = .denied
        }

        return [currentState, serviceState].max(by: { locationPriority($0) < locationPriority($1) }) ?? currentState
    }

    private func locationPriority(_ state: LocationPermissionState) -> Int {
        switch state {
        case .notDetermined:
            return 0
        case .denied:
            return 1
        case .whenInUse:
            return 2
        case .always:
            return 3
        }
    }
}
