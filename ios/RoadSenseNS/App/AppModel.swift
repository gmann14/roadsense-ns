import CoreLocation
import Foundation
import Observation
import UIKit

enum PotholeActionSubmissionResult: Equatable {
    case queued(UUID)
    case unavailableLocation
    case insidePrivacyZone
}

struct PotholePhotoCaptureContext: Equatable {
    let coordinateLabel: String
}

enum PotholePhotoSubmissionResult: Equatable {
    case queued(UUID)
    case unavailableLocation
    case insidePrivacyZone
    case outsideCoverage
}

struct CollectionDiagnosticsSummary: Equatable {
    let isMonitoring: Bool
    let isCollecting: Bool
    let lastMonitoringStartedAt: Date?
    let lastCollectionStartedAt: Date?
    let lastCollectionStoppedAt: Date?
    let lastLocationSampleAt: Date?
    let lastDrivingEventAt: Date?
    let lastDrivingEventWasDriving: Bool?
    let lastPotholeCandidateAt: Date?

    static let empty = CollectionDiagnosticsSummary(
        isMonitoring: false,
        isCollecting: false,
        lastMonitoringStartedAt: nil,
        lastCollectionStartedAt: nil,
        lastCollectionStoppedAt: nil,
        lastLocationSampleAt: nil,
        lastDrivingEventAt: nil,
        lastDrivingEventWasDriving: nil,
        lastPotholeCandidateAt: nil
    )
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
    private let potholePhotoStore: PotholePhotoStore
    private let readingStore: ReadingStore
    private let uploadQueueStore: UploadQueueStore
    private let uploadDrainCoordinator: UploadDrainCoordinator
    private let sensorCoordinator: SensorCoordinator
    private let haptics: HapticsServicing
    private let logger: RoadSenseLogger
    private let potholeLocator = ManualPotholeLocator()

    private(set) var snapshot: PermissionSnapshot
    private(set) var isRequestingPermissions = false
    private(set) var isPassiveMonitoringEnabled = false
    private(set) var isActivelyCollecting = false
    private(set) var isCollectionPausedByUser = false
    private(set) var pendingUploadCount = 0
    private(set) var uploadStatusSummary = UploadQueueStatusSummary.empty
    private(set) var potholeActionStatusSummary = PotholeActionStatusSummary.empty
    private(set) var potholePhotoStatusSummary = PotholePhotoStatusSummary.empty
    private(set) var failedPotholeActions: [FailedPotholeActionSummary] = []
    private(set) var failedPotholePhotos: [FailedPotholePhotoSummary] = []
    private(set) var acceptedReadingCount = 0
    private(set) var privacyFilteredCount = 0
    private(set) var localDriveOverlayPoints: [LocalDriveOverlayPoint] = []
    private(set) var pendingPotholeCoordinates: [CLLocationCoordinate2D] = []
    private(set) var userStatsSummary = UserStatsSummary.zero
    private(set) var collectionDiagnostics = CollectionDiagnosticsSummary.empty

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
        self.potholePhotoStore = container.potholePhotoStore
        self.readingStore = container.readingStore
        self.userStatsStore = container.userStatsStore
        self.uploadQueueStore = container.uploadQueueStore
        self.uploadDrainCoordinator = container.uploadDrainCoordinator
        self.sensorCoordinator = container.sensorCoordinator
        self.haptics = container.haptics
        self.logger = container.logger

        let privacyZones = Self.resolvePrivacyZoneState(
            defaults: defaults,
            key: privacyZoneDecisionKey,
            privacyZoneStore: container.privacyZoneStore
        )
        self.snapshot = container.permissions.currentSnapshot(privacyZones: privacyZones)
        _ = try? container.potholeActionStore.promoteExpiredPendingUndoActions()
        _ = try? container.potholeActionStore.recoverRecoverableFailures()
        _ = try? container.potholeActionStore.reconcileManualReportStats()
        self.uploadStatusSummary = (try? container.uploadQueueStore.statusSummary()) ?? .empty
        self.potholeActionStatusSummary = (try? container.potholeActionStore.statusSummary()) ?? .empty
        self.potholePhotoStatusSummary = (try? container.potholePhotoStore.statusSummary()) ?? .empty
        self.failedPotholeActions = (try? container.potholeActionStore.failedPermanentActions()) ?? []
        self.failedPotholePhotos = (try? container.potholePhotoStore.failedPermanentReports()) ?? []
        self.pendingUploadCount = ((try? container.uploadQueueStore.pendingReadingCount()) ?? 0)
            + ((try? container.potholeActionStore.pendingCount()) ?? 0)
            + potholePhotoStatusSummary.pendingCount
        self.acceptedReadingCount = (try? container.readingStore.acceptedReadingCount()) ?? 0
        self.privacyFilteredCount = (try? container.readingStore.privacyFilteredReadingCount()) ?? 0
        self.localDriveOverlayPoints = (try? container.readingStore.localDriveOverlayPoints()) ?? []
        self.pendingPotholeCoordinates = (try? container.potholeActionStore.pendingManualReportCoordinates()) ?? []
        self.userStatsSummary = (try? container.userStatsStore.summary()) ?? .zero
        self.isCollectionPausedByUser = defaults.bool(forKey: collectionPausedKey)
        self.sensorCoordinator.stateDidChange = { [weak self] in
            self?.refreshCollectionStats()
        }
        syncPassiveMonitoringState()
        refreshCollectionStats()
    }

    var readiness: CollectionReadiness {
        CollectionReadiness.evaluate(snapshot)
    }

    /// Latest reported speed in km/h, derived from the most recent location sample.
    /// Returns `nil` when no fresh sample is available. Used by the camera-safety
    /// banner per `docs/reviews/2026-04-24-design-audit.md` §13.4.
    var currentSpeedKmh: Double? {
        locationService.latestSample?.speedKmh
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

    func retryFailedPotholePhotos(ids: [UUID]? = nil) async {
        do {
            try potholePhotoStore.retryFailedReports(ids: ids)
            _ = await uploadDrainCoordinator.requestDrain(reason: .diagnosticsRetry)
            refreshCollectionStats()
        } catch {
            logger.error("failed to retry pothole photos: \(error.localizedDescription)")
        }
    }

    func retryFailedPotholeActions(ids: [UUID]? = nil) async {
        do {
            try potholeActionStore.retryFailedActions(ids: ids)
            _ = await uploadDrainCoordinator.requestDrain(reason: .diagnosticsRetry)
            refreshCollectionStats()
        } catch {
            logger.error("failed to retry pothole actions: \(error.localizedDescription)")
        }
    }

    func deleteFailedPotholePhoto(id: UUID) {
        do {
            try potholePhotoStore.deleteReport(id: id)
            refreshCollectionStats()
        } catch {
            logger.error("failed to delete pothole photo: \(error.localizedDescription)")
        }
    }

    func handleAppDidBecomeActive() async {
        _ = try? potholeActionStore.promoteExpiredPendingUndoActions()
        _ = try? potholeActionStore.recoverRecoverableFailures()
        _ = try? potholeActionStore.reconcileManualReportStats()
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

            guard readiness.backgroundCollection == .upgradeRequired,
                  let settingsURL = URL(string: UIApplication.openSettingsURLString) else {
                return
            }

            _ = await UIApplication.shared.open(settingsURL)
        }
    }

    func deleteLocalContributionData() throws {
        try potholeActionStore.deleteAllActions()
        try potholePhotoStore.deleteAllReports()
        try readingStore.deleteAllContributionData()
        refreshCollectionStats()
    }

    func statsSummary() throws -> UserStatsSummary {
        try userStatsStore.summary()
    }

    func fetchSegmentDetail(id: UUID) async throws -> SegmentDetailResponse {
        try await apiClient.fetchSegmentDetail(id: id)
    }

    func markPothole(now: Date = Date()) -> PotholeActionSubmissionResult {
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
            haptics.notification(.warning)
            return .unavailableLocation
        }

        guard !isInsidePrivacyZone(chosenSample) else {
            haptics.notification(.warning)
            return .insidePrivacyZone
        }

        do {
            let sensorBackedCandidate = sensorCoordinator.strongestRecentPotholeCandidate(
                near: chosenSample,
                now: now
            )
            let action = try potholeActionStore.queueManualReport(
                sample: chosenSample,
                sensorBackedCandidate: sensorBackedCandidate,
                now: now
            )
            logger.info("manual pothole report queued: \(action.id.uuidString)")
            schedulePendingUndoPromotion(for: action.id)
            haptics.notification(.success)
            return .queued(action.id)
        } catch {
            logger.error("failed to queue pothole report: \(error.localizedDescription)")
            haptics.notification(.warning)
            return .unavailableLocation
        }
    }

    func queuePotholeFollowUp(
        potholeReportID: UUID,
        actionType: PotholeActionType,
        now: Date = Date()
    ) -> PotholeActionSubmissionResult {
        guard actionType != .manualReport else {
            return .unavailableLocation
        }

        guard let sample = locationService.latestSample,
              hasUsableLocation(sample, now: now) else {
            return .unavailableLocation
        }

        guard !isInsidePrivacyZone(sample) else {
            return .insidePrivacyZone
        }

        do {
            let action = try potholeActionStore.queueFollowUpAction(
                potholeReportID: potholeReportID,
                actionType: actionType,
                sample: sample,
                now: now
            )
            logger.info("pothole follow-up queued: \(action.id.uuidString) type=\(actionType.rawValue)")
            Task { @MainActor in
                _ = await uploadDrainCoordinator.requestDrain(reason: .foreground)
                refreshCollectionStats()
            }
            return .queued(action.id)
        } catch {
            logger.error("failed to queue pothole follow-up: \(error.localizedDescription)")
            return .unavailableLocation
        }
    }

    func followUpPromptCandidate(
        for potholes: [SegmentPothole],
        now: Date = Date()
    ) -> SegmentPothole? {
        guard let sample = locationService.latestSample,
              hasFreshStoppedLocation(sample, now: now),
              !isInsidePrivacyZone(sample) else {
            return nil
        }

        let currentLocation = CLLocation(latitude: sample.latitude, longitude: sample.longitude)
        return potholes
            .filter { $0.status != "resolved" }
            .sorted { lhs, rhs in
                distance(from: currentLocation, to: lhs) < distance(from: currentLocation, to: rhs)
            }
            .first(where: { distance(from: currentLocation, to: $0) <= 35 })
    }

    func potholePhotoCaptureContext(now: Date = Date()) -> PotholePhotoCaptureContext? {
        guard let sample = locationService.latestSample,
              hasUsableLocation(sample, now: now) else {
            return nil
        }

        return PotholePhotoCaptureContext(
            coordinateLabel: "Near \(formattedCoordinate(sample.latitude)), \(formattedCoordinate(sample.longitude))"
        )
    }

    func submitPotholePhoto(
        rawImageData: Data,
        segmentID: UUID? = nil,
        now: Date = Date()
    ) async -> PotholePhotoSubmissionResult {
        guard let sample = locationService.latestSample else {
            return .unavailableLocation
        }

        guard hasUsableLocation(sample, now: now) else {
            return .unavailableLocation
        }

        guard !isInsidePrivacyZone(sample) else {
            return .insidePrivacyZone
        }

        guard isInsidePhotoCoverage(sample) else {
            return .outsideCoverage
        }

        do {
            let prepared = try await Task.detached(priority: .userInitiated) {
                try PotholePhotoProcessor.prepareCapturedPhoto(rawJPEGData: rawImageData)
            }.value
            let record = try potholePhotoStore.queuePreparedReport(
                segmentID: segmentID,
                photoFileURL: prepared.fileURL,
                latitude: sample.latitude,
                longitude: sample.longitude,
                accuracyM: sample.horizontalAccuracyMeters,
                capturedAt: now,
                byteSize: prepared.byteSize,
                sha256Hex: prepared.sha256Hex
            )
            Task { @MainActor in
                _ = await uploadDrainCoordinator.requestDrain(reason: .foreground)
                refreshCollectionStats()
            }
            logger.info("pothole photo queued: \(record.id.uuidString)")
            return .queued(record.id)
        } catch {
            logger.error("failed to queue pothole photo: \(error.localizedDescription)")
            return .unavailableLocation
        }
    }

    func undoPotholeReport(id: UUID, now: Date = Date()) {
        do {
            try potholeActionStore.discard(id: id, now: now)
            logger.info("manual pothole report discarded: \(id.uuidString)")
        } catch {
            logger.error("failed to discard pothole report: \(error.localizedDescription)")
        }
    }

    private func updatePrivacyZoneDecision(_ state: PrivacyZoneSetupState) {
        defaults.set(state.rawValue, forKey: privacyZoneDecisionKey)
        snapshot = resolvedPermissionSnapshot(privacyZones: state)
    }

    func refreshCollectionStats() {
        _ = try? potholeActionStore.promoteExpiredPendingUndoActions()
        _ = try? potholeActionStore.reconcileManualReportStats()
        uploadStatusSummary = (try? uploadQueueStore.statusSummary()) ?? .empty
        potholeActionStatusSummary = (try? potholeActionStore.statusSummary()) ?? .empty
        potholePhotoStatusSummary = (try? potholePhotoStore.statusSummary()) ?? .empty
        failedPotholeActions = (try? potholeActionStore.failedPermanentActions()) ?? []
        failedPotholePhotos = (try? potholePhotoStore.failedPermanentReports()) ?? []
        pendingUploadCount = ((try? uploadQueueStore.pendingReadingCount()) ?? 0)
            + ((try? potholeActionStore.pendingCount()) ?? 0)
            + potholePhotoStatusSummary.pendingCount
        acceptedReadingCount = (try? readingStore.acceptedReadingCount()) ?? 0
        privacyFilteredCount = (try? readingStore.privacyFilteredReadingCount()) ?? 0
        localDriveOverlayPoints = (try? readingStore.localDriveOverlayPoints()) ?? []
        pendingPotholeCoordinates = (try? potholeActionStore.pendingManualReportCoordinates()) ?? []
        userStatsSummary = (try? userStatsStore.summary()) ?? .zero
        isCollectionPausedByUser = defaults.bool(forKey: collectionPausedKey)
        isPassiveMonitoringEnabled = sensorCoordinator.monitoringState.isMonitoring
        isActivelyCollecting = sensorCoordinator.monitoringState.isCollecting
        let diagnostics = sensorCoordinator.diagnostics
        collectionDiagnostics = CollectionDiagnosticsSummary(
            isMonitoring: diagnostics.isMonitoring,
            isCollecting: diagnostics.isCollecting,
            lastMonitoringStartedAt: diagnostics.lastMonitoringStartedAt,
            lastCollectionStartedAt: diagnostics.lastCollectionStartedAt,
            lastCollectionStoppedAt: diagnostics.lastCollectionStoppedAt,
            lastLocationSampleAt: diagnostics.lastLocationSampleAt,
            lastDrivingEventAt: diagnostics.lastDrivingEventAt,
            lastDrivingEventWasDriving: diagnostics.lastDrivingEventWasDriving,
            lastPotholeCandidateAt: diagnostics.lastPotholeCandidateAt
        )
    }

    private func hasUsableLocation(_ sample: LocationSample, now: Date) -> Bool {
        let ageSeconds = now.timeIntervalSince1970 - sample.timestamp
        return ageSeconds <= 10 && sample.horizontalAccuracyMeters <= 25
    }

    private func hasFreshStoppedLocation(_ sample: LocationSample, now: Date) -> Bool {
        let ageSeconds = now.timeIntervalSince1970 - sample.timestamp
        return ageSeconds <= 10 && sample.speedKmh < 5
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

    private func isInsidePhotoCoverage(_ sample: LocationSample) -> Bool {
        sample.longitude >= -66.5
            && sample.longitude <= -59.5
            && sample.latitude >= 43.3
            && sample.latitude <= 47.1
    }

    private func schedulePendingUndoPromotion(for actionID: UUID) {
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(5.1))
            guard let self else { return }

            do {
                let promoted = try self.potholeActionStore.promoteExpiredPendingUndoActions()
                guard promoted > 0 else { return }

                self.logger.info("manual pothole report ready for upload: \(actionID.uuidString)")
                _ = await self.uploadDrainCoordinator.requestDrain(reason: .foreground)
                self.refreshCollectionStats()
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

    private func distance(from currentLocation: CLLocation, to pothole: SegmentPothole) -> CLLocationDistance {
        currentLocation.distance(
            from: CLLocation(latitude: pothole.latitude, longitude: pothole.longitude)
        )
    }

    private func formattedCoordinate(_ value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(4)))
    }
}
