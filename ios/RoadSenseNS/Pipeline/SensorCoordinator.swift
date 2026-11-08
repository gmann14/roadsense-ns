import CoreLocation
import Foundation

struct SensorCollectionDiagnostics: Equatable {
    let isMonitoring: Bool
    let isCollecting: Bool
    let lastMonitoringStartedAt: Date?
    let lastCollectionStartedAt: Date?
    let lastCollectionStoppedAt: Date?
    let lastLocationSampleAt: Date?
    let lastDrivingEventAt: Date?
    let lastDrivingEventWasDriving: Bool?
    let lastPotholeCandidateAt: Date?

    static let empty = SensorCollectionDiagnostics(
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
final class SensorCoordinator {
    private static let fragmentedSessionMergeGapSeconds: TimeInterval = 60
    private static let locationBootstrapSpeedKmh = 45.0
    private static let locationBootstrapAccuracyMeters = 50.0
    private static let manualPotholeCandidateRetentionSeconds: TimeInterval = 30

    private let locationService: LocationServicing
    private let motionService: MotionServicing
    private let drivingDetector: DrivingDetecting
    private let thermalMonitor: ThermalMonitoring
    private let privacyZoneStore: PrivacyZoneStoring
    private let readingStore: ReadingStore
    private let logger: RoadSenseLogger
    private let checkpointStore: SensorCheckpointStore
    private let nowProvider: @Sendable () -> Date
    private let scheduleUploadDrain: @MainActor (Date) -> Void
    private let stopCollectionGracePeriod: Duration
    var stateDidChange: (@MainActor () -> Void)?

    private var drivingTask: Task<Void, Never>?
    private var locationTask: Task<Void, Never>?
    private var motionTask: Task<Void, Never>?
    private var thermalTask: Task<Void, Never>?
    private var pendingStopTask: Task<Void, Never>?

    private var readingBuilder = ReadingBuilder()
    private var potholeDetector = PotholeDetector()
    private var activePrivacyZones: [PrivacyZone] = []
    private var latestLocation: LocationSample?
    private var recentPotholes: [PotholeCandidate] = []
    private var currentDriveSessionID: UUID?
    private var isMonitoring = false
    private var isCollecting = false
    private var lastCheckpointAt: Date?
    private var lastMonitoringStartedAt: Date?
    private var lastCollectionStartedAt: Date?
    private var lastCollectionStoppedAt: Date?
    private var lastLocationSampleAt: Date?
    private var lastDrivingEventAt: Date?
    private var lastDrivingEventWasDriving: Bool?
    private var lastPotholeCandidateAt: Date?
    private var shouldResumeCollectionAfterRestore = false
    /// True while the latest fix was inside a privacy zone. Motion samples and
    /// pothole detection are skipped so nothing is derived from in-zone travel.
    private var isInsidePrivacyZone = false
    /// True while the device is at `.serious`/`.critical` thermal state:
    /// high-rate sensors are stopped until it cools down (prelaunch P1-2).
    private(set) var isThermallyPaused = false
    /// Set when collection was running (or a drive started) during a thermal
    /// pause, so collection resumes once the device recovers.
    private var shouldResumeAfterThermalRecovery = false

    init(
        locationService: LocationServicing,
        motionService: MotionServicing,
        drivingDetector: DrivingDetecting,
        thermalMonitor: ThermalMonitoring,
        privacyZoneStore: PrivacyZoneStoring,
        readingStore: ReadingStore,
        logger: RoadSenseLogger,
        checkpointStore: SensorCheckpointStore,
        stopCollectionGracePeriod: Duration = .seconds(60),
        nowProvider: @escaping @Sendable () -> Date = { Date() },
        scheduleUploadDrain: @escaping @MainActor (Date) -> Void
    ) {
        self.locationService = locationService
        self.motionService = motionService
        self.drivingDetector = drivingDetector
        self.thermalMonitor = thermalMonitor
        self.privacyZoneStore = privacyZoneStore
        self.readingStore = readingStore
        self.logger = logger
        self.checkpointStore = checkpointStore
        self.nowProvider = nowProvider
        self.stopCollectionGracePeriod = stopCollectionGracePeriod
        self.scheduleUploadDrain = scheduleUploadDrain
    }

    convenience init(
        locationService: LocationServicing,
        motionService: MotionServicing,
        drivingDetector: DrivingDetecting,
        thermalMonitor: ThermalMonitoring,
        privacyZoneStore: PrivacyZoneStoring,
        readingStore: ReadingStore,
        logger: RoadSenseLogger,
        checkpointStore: SensorCheckpointStore,
        scheduleUploadDrain: @escaping @MainActor (Date) -> Void
    ) {
        self.init(
            locationService: locationService,
            motionService: motionService,
            drivingDetector: drivingDetector,
            thermalMonitor: thermalMonitor,
            privacyZoneStore: privacyZoneStore,
            readingStore: readingStore,
            logger: logger,
            checkpointStore: checkpointStore,
            stopCollectionGracePeriod: .seconds(60),
            scheduleUploadDrain: scheduleUploadDrain
        )
    }

    func startMonitoring() {
        guard !isMonitoring else {
            return
        }

        do {
            activePrivacyZones = try privacyZoneStore.fetchAll().map {
                PrivacyZone(
                    latitude: $0.latitude,
                    longitude: $0.longitude,
                    radiusMeters: $0.radiusM
                )
            }
        } catch {
            logger.error("failed to load privacy zones: \(error.localizedDescription)")
            activePrivacyZones = []
        }

        let restoredCheckpoint = restoreCheckpointIfAvailable()
        if !restoredCheckpoint {
            sealOpenDriveSessionsIfNeeded()
        }
        repairFragmentedDriveSessionsIfNeeded()

        isMonitoring = true
        lastMonitoringStartedAt = nowProvider()
        stateDidChange?()

        // Streams are single-use: cancelling a consuming task (stopMonitoring)
        // terminates the stream for good, so each monitoring session must
        // request fresh ones before the services start yielding.
        let locationSamples = locationService.makeSampleStream()
        let motionSamples = motionService.makeSampleStream()
        let drivingEvents = drivingDetector.makeEventStream()
        let thermalStates = thermalMonitor.makeStateStream()
        applyThermalState(thermalMonitor.currentState)

        locationService.startPassiveMonitoring()
        drivingDetector.start()

        locationTask = Task { [weak self] in
            guard let self else { return }
            for await sample in locationSamples {
                await self.handleLocationSample(sample)
            }
        }

        motionTask = Task { [weak self] in
            guard let self else { return }
            for await sample in motionSamples {
                await self.handleMotionSample(sample)
            }
        }

        drivingTask = Task { [weak self] in
            guard let self else { return }
            for await isDriving in drivingEvents {
                self.handleDrivingEvent(isDriving)
                if isDriving {
                    await self.cancelPendingStopCollection()
                    await self.startCollection()
                } else {
                    await self.scheduleStopCollectionIfNeeded()
                }
            }
        }

        thermalTask = Task { [weak self] in
            guard let self else { return }
            for await state in thermalStates {
                await self.handleThermalStateChange(state)
            }
        }

        if shouldResumeCollectionAfterRestore {
            shouldResumeCollectionAfterRestore = false
            Task { [weak self] in
                await self?.startCollection()
            }
        }

        logger.info("sensor monitoring started")
    }

    func stopMonitoring() {
        isMonitoring = false
        locationService.stopPassiveMonitoring()
        stateDidChange?()
        drivingTask?.cancel()
        locationTask?.cancel()
        motionTask?.cancel()
        thermalTask?.cancel()
        drivingTask = nil
        locationTask = nil
        motionTask = nil
        thermalTask = nil
        isThermallyPaused = false
        shouldResumeAfterThermalRecovery = false
        pendingStopTask?.cancel()
        pendingStopTask = nil
        drivingDetector.stop()
        sealCurrentDriveSessionIfNeeded()
        stopServicesAndReset()
        try? checkpointStore.clear()
        logger.info("sensor monitoring stopped")
    }

    func refreshPrivacyZones() {
        do {
            activePrivacyZones = try privacyZoneStore.fetchAll().map {
                PrivacyZone(
                    latitude: $0.latitude,
                    longitude: $0.longitude,
                    radiusMeters: $0.radiusM
                )
            }
        } catch {
            logger.error("failed to refresh privacy zones: \(error.localizedDescription)")
        }
    }

    var monitoringState: (isMonitoring: Bool, isCollecting: Bool) {
        (isMonitoring, isCollecting)
    }

    /// Forgets the in-progress drive after its data was deleted ("Delete local
    /// data" or deleting the active drive) so later readings start a fresh
    /// session instead of pointing at a session row that no longer exists.
    /// Collection itself keeps running.
    func resetCurrentDriveSession() {
        currentDriveSessionID = nil
        readingBuilder = ReadingBuilder()
        potholeDetector = PotholeDetector()
        recentPotholes = []
        latestLocation = nil
        lastCheckpointAt = nil
        do {
            try checkpointStore.clear()
        } catch {
            logger.error("failed to clear sensor checkpoint: \(error.localizedDescription)")
        }
        stateDidChange?()
    }

    /// Called after a single drive was deleted locally.
    func handleDriveSessionDeleted(id: UUID) {
        guard currentDriveSessionID == id else {
            return
        }
        resetCurrentDriveSession()
    }

    var diagnostics: SensorCollectionDiagnostics {
        SensorCollectionDiagnostics(
            isMonitoring: isMonitoring,
            isCollecting: isCollecting,
            lastMonitoringStartedAt: lastMonitoringStartedAt,
            lastCollectionStartedAt: lastCollectionStartedAt,
            lastCollectionStoppedAt: lastCollectionStoppedAt,
            lastLocationSampleAt: lastLocationSampleAt,
            lastDrivingEventAt: lastDrivingEventAt,
            lastDrivingEventWasDriving: lastDrivingEventWasDriving,
            lastPotholeCandidateAt: lastPotholeCandidateAt
        )
    }

    func strongestRecentPotholeCandidate(
        near sample: LocationSample,
        now: Date,
        maxAgeSeconds: TimeInterval = 20,
        maxDistanceMeters: CLLocationDistance = 25
    ) -> PotholeCandidate? {
        let tapTime = now.timeIntervalSince1970
        let tapLocation = CLLocation(latitude: sample.latitude, longitude: sample.longitude)

        return recentPotholes
            .filter { candidate in
                let age = tapTime - candidate.timestamp
                guard age >= 0 && age <= maxAgeSeconds else {
                    return false
                }

                let candidateLocation = CLLocation(latitude: candidate.latitude, longitude: candidate.longitude)
                return tapLocation.distance(from: candidateLocation) <= maxDistanceMeters
            }
            .max { $0.magnitudeG < $1.magnitudeG }
    }

    private func startCollection() async {
        await cancelPendingStopCollection()
        guard isMonitoring, !isCollecting else {
            return
        }

        guard !isThermallyPaused else {
            shouldResumeAfterThermalRecovery = true
            logger.info("sensor collection deferred: device thermal state is serious/critical")
            return
        }

        do {
            try locationService.start()
            try motionService.start(hz: 50)
            isCollecting = true
            lastCollectionStartedAt = nowProvider()
            stateDidChange?()
            logger.info("sensor collection started")
        } catch {
            logger.error("failed to start collection: \(error.localizedDescription)")
            stopServicesAndReset()
        }
    }

    private func stopCollection() async {
        guard isCollecting else {
            return
        }

        sealCurrentDriveSessionIfNeeded()
        lastCollectionStoppedAt = nowProvider()
        stopServicesAndReset()
        // Without this, a checkpoint written with wasCollecting: true survives
        // on disk after collection legitimately stops (e.g. driving-false
        // grace period elapses while parked). If the app is then killed and
        // relaunched within the checkpoint's restore window, restoreCheckpointIfAvailable
        // reads the stale wasCollecting: true and resumes full-power GPS +
        // 50Hz motion collection while stationary, draining battery for no
        // reason. stopMonitoring already clears the checkpoint on its path;
        // this mirrors that for the stopCollection-only path.
        try? checkpointStore.clear()
        logger.info("sensor collection stopped")
        scheduleUploadDrain(nowProvider().addingTimeInterval(15 * 60))
    }

    private func stopServicesAndReset() {
        pendingStopTask?.cancel()
        pendingStopTask = nil
        locationService.stop()
        motionService.stop()
        isCollecting = false
        stateDidChange?()
        readingBuilder = ReadingBuilder()
        potholeDetector = PotholeDetector()
        recentPotholes = []
        latestLocation = nil
        isInsidePrivacyZone = false
        currentDriveSessionID = nil
        lastCheckpointAt = nil
    }

    private func handleLocationSample(_ sample: LocationSample) async {
        lastLocationSampleAt = Date(timeIntervalSince1970: sample.timestamp)
        stateDidChange?()

        if isMonitoring,
           !isCollecting,
           sample.speedKmh >= Self.locationBootstrapSpeedKmh,
           sample.horizontalAccuracyMeters <= Self.locationBootstrapAccuracyMeters {
            logger.info("location movement bootstrap started collection speed=\(sample.speedKmh)")
            await startCollection()
        }

        guard isCollecting else {
            return
        }

        // The privacy-zone check runs before anything else touches the
        // sample: an in-zone fix must never become `latestLocation`, a drive
        // session's start coordinate, a pothole stamp, or checkpoint content.
        if PrivacyZoneFilter.shouldDrop(sample, zones: activePrivacyZones) {
            handlePrivacyZoneSample(sample)
            return
        }

        isInsidePrivacyZone = false
        latestLocation = sample
        let driveSessionID = ensureCurrentDriveSession(for: sample)

        guard let window = readingBuilder.addLocationSample(sample) else {
            return
        }

        let deviceState = DeviceCollectionState(
            thermalState: map(thermalMonitor.currentState),
            isLowPowerModeEnabled: ProcessInfo.processInfo.isLowPowerModeEnabled
        )

        let windowEnd = window.startedAt + window.durationSeconds
        let potholesInWindow = recentPotholes.filter {
            $0.timestamp >= window.startedAt && $0.timestamp <= windowEnd
        }

        switch ReadingWindowProcessor.process(
            window: window,
            deviceState: deviceState,
            potholeCandidates: potholesInWindow
        ) {
        case let .accepted(candidate):
            do {
                try readingStore.saveAccepted(candidate, driveSessionID: driveSessionID)
            } catch {
                logger.error("failed to persist accepted reading: \(error.localizedDescription)")
            }
        case let .rejected(reason):
            logger.info("reading window rejected: \(String(describing: reason))")
        }

        recentPotholes.removeAll {
            $0.timestamp < windowEnd - Self.manualPotholeCandidateRetentionSeconds
        }
        persistCheckpointIfNeeded(force: false)
    }

    private func handlePrivacyZoneSample(_ sample: LocationSample) {
        // Count-only bookkeeping, attached to the current drive if one is
        // already open. No session is created from an in-zone fix; if the
        // drive started inside a zone the session opens at the first fix
        // outside it and adopts these rows then.
        do {
            try readingStore.savePrivacyFilteredSample(sample, driveSessionID: currentDriveSessionID)
        } catch {
            logger.error("failed to persist privacy-filtered sample: \(error.localizedDescription)")
        }

        let wasInsideZone = isInsidePrivacyZone
        isInsidePrivacyZone = true
        latestLocation = nil
        readingBuilder = ReadingBuilder()
        potholeDetector = PotholeDetector()
        recentPotholes = []
        if !wasInsideZone {
            persistCheckpointIfNeeded(force: true)
        }
    }

    private func handleMotionSample(_ sample: MotionSample) async {
        guard isCollecting, !isInsidePrivacyZone else {
            return
        }

        readingBuilder.addMotionSample(sample)

        guard let latestLocation else {
            return
        }

        if let candidate = potholeDetector.ingest(
            verticalAccelerationG: sample.verticalAcceleration,
            currentLocation: latestLocation
        ) {
            recentPotholes.append(candidate)
            lastPotholeCandidateAt = Date(timeIntervalSince1970: candidate.timestamp)
            stateDidChange?()
        }
        persistCheckpointIfNeeded(force: false)
    }

    private func handleDrivingEvent(_ isDriving: Bool) {
        lastDrivingEventAt = nowProvider()
        lastDrivingEventWasDriving = isDriving
        stateDidChange?()
    }

    private func map(_ state: ProcessInfo.ThermalState) -> ThermalCollectionState {
        switch state {
        case .nominal:
            return .nominal
        case .fair:
            return .fair
        case .serious:
            return .serious
        case .critical:
            return .critical
        @unknown default:
            return .serious
        }
    }

    private func restoreCheckpointIfAvailable() -> Bool {
        do {
            guard let checkpoint = try checkpointStore.load(maxAge: 30 * 60) else {
                currentDriveSessionID = nil
                shouldResumeCollectionAfterRestore = false
                return false
            }

            readingBuilder = ReadingBuilder(snapshot: checkpoint.readingBuilder)
            potholeDetector = PotholeDetector(snapshot: checkpoint.potholeDetector)
            latestLocation = checkpoint.latestLocation
            recentPotholes = checkpoint.recentPotholes
            isCollecting = false
            shouldResumeCollectionAfterRestore = checkpoint.wasCollecting
            currentDriveSessionID = try readingStore.activeDriveSessionID()
            lastCheckpointAt = checkpoint.savedAt
            stateDidChange?()
            logger.info("restored fresh sensor checkpoint")
            return true
        } catch {
            logger.error("failed to restore sensor checkpoint: \(error.localizedDescription)")
            currentDriveSessionID = nil
            shouldResumeCollectionAfterRestore = false
            return false
        }
    }

    private func persistCheckpointIfNeeded(force: Bool) {
        let now = nowProvider()
        if !force, let lastCheckpointAt, now.timeIntervalSince(lastCheckpointAt) < 60 {
            return
        }

        // Privacy zones are processed on-device and the server must never see
        // readings near a protected zone (home/work). In-zone fixes never reach
        // `latestLocation`, the reading builder or `recentPotholes` (all are
        // cleared on zone entry), so every checkpoint write is zone-free,
        // including the periodic one from the motion path.
        let checkpoint = SensorCheckpoint(
            savedAt: now,
            wasCollecting: isCollecting,
            latestLocation: isInsidePrivacyZone ? nil : latestLocation,
            recentPotholes: isInsidePrivacyZone ? [] : recentPotholes,
            readingBuilder: readingBuilder.snapshot(),
            potholeDetector: potholeDetector.snapshot()
        )

        do {
            try checkpointStore.save(checkpoint)
            lastCheckpointAt = now
        } catch {
            logger.error("failed to save sensor checkpoint: \(error.localizedDescription)")
        }
    }

    private func ensureCurrentDriveSession(for sample: LocationSample) -> UUID? {
        if let currentDriveSessionID {
            return currentDriveSessionID
        }

        do {
            let sessionID = try readingStore.ensureActiveDriveSession(
                for: sample,
                adoptingPrivacyFilteredSince: lastCollectionStartedAt
            )
            currentDriveSessionID = sessionID
            return sessionID
        } catch {
            logger.error("failed to create drive session: \(error.localizedDescription)")
            return nil
        }
    }

    private func sealCurrentDriveSessionIfNeeded() {
        guard let currentDriveSessionID else {
            return
        }

        do {
            if let summary = try readingStore.finalizeDriveSession(
                id: currentDriveSessionID,
                fallbackEndSample: latestLocation
            ) {
                logger.info(
                    "drive session sealed id=\(summary.sessionID.uuidString) eligible=\(summary.eligibleReadingCount) trimmed=\(summary.trimmedReadingCount) privacy_filtered=\(summary.privacyFilteredReadingCount)"
                )
            }
        } catch {
            logger.error("failed to seal drive session: \(error.localizedDescription)")
        }

        self.currentDriveSessionID = nil
        repairFragmentedDriveSessionsIfNeeded()
    }

    private func sealOpenDriveSessionsIfNeeded() {
        do {
            let summaries = try readingStore.finalizeOpenDriveSessions()
            guard !summaries.isEmpty else {
                return
            }

            let eligibleCount = summaries.reduce(0) { $0 + $1.eligibleReadingCount }
            let trimmedCount = summaries.reduce(0) { $0 + $1.trimmedReadingCount }
            logger.info("sealed \(summaries.count) abandoned drive session(s): eligible=\(eligibleCount) trimmed=\(trimmedCount)")
        } catch {
            logger.error("failed to seal abandoned drive sessions: \(error.localizedDescription)")
        }
    }

    private func scheduleStopCollectionIfNeeded() async {
        guard isCollecting, pendingStopTask == nil else {
            return
        }

        pendingStopTask = Task { @MainActor [weak self] in
            guard let self else { return }

            do {
                try await Task.sleep(for: stopCollectionGracePeriod)
            } catch is CancellationError {
                return
            } catch {
                return
            }

            guard !Task.isCancelled else {
                return
            }

            self.pendingStopTask = nil
            await self.stopCollection()
        }
    }

    // MARK: - Thermal

    private func handleThermalStateChange(_ state: ProcessInfo.ThermalState) async {
        let wasPaused = isThermallyPaused
        applyThermalState(state)

        if isThermallyPaused, !wasPaused {
            logger.info("thermal state \(String(describing: map(state))): pausing high-rate sensors")
            if isCollecting {
                shouldResumeAfterThermalRecovery = true
                await stopCollection()
            }
        } else if !isThermallyPaused, wasPaused {
            logger.info("thermal state recovered: \(String(describing: map(state)))")
            let shouldResume = shouldResumeAfterThermalRecovery && lastDrivingEventWasDriving != false
            shouldResumeAfterThermalRecovery = false
            if shouldResume {
                await startCollection()
            }
        }
        stateDidChange?()
    }

    private func applyThermalState(_ state: ProcessInfo.ThermalState) {
        switch map(state) {
        case .serious, .critical:
            isThermallyPaused = true
        case .nominal, .fair:
            isThermallyPaused = false
        }
    }

    private func cancelPendingStopCollection() async {
        pendingStopTask?.cancel()
        pendingStopTask = nil
    }

    private func repairFragmentedDriveSessionsIfNeeded() {
        do {
            let summary = try readingStore.repairFragmentedDriveSessions(
                now: nowProvider(),
                maximumGapSeconds: Self.fragmentedSessionMergeGapSeconds
            )
            guard summary.fragmentedGroupCount > 0 else {
                return
            }

            logger.info(
                "repaired fragmented drive sessions groups=\(summary.fragmentedGroupCount) recovered=\(summary.recoveredEligibleReadingCount) eligible=\(summary.eligibleReadingCount) trimmed=\(summary.trimmedReadingCount)"
            )
        } catch {
            logger.error("failed to repair fragmented drive sessions: \(error.localizedDescription)")
        }
    }
}
