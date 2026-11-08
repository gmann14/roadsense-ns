import CoreLocation
import Foundation

/// The one path for a manual "mark pothole": the in-app button (through
/// `AppModel.markPothole`) and the Siri / Shortcuts App Intent both use it,
/// so the location choice, privacy-zone check and queueing are identical.
@MainActor
final class ManualPotholeReporter {
    private let locationService: LocationServicing
    private let privacyZoneStore: PrivacyZoneStoring
    private let potholeActionStore: PotholeActionStore
    private let sensorCoordinator: SensorCoordinator
    private let haptics: HapticsServicing
    private let logger: RoadSenseLogger
    private let potholeLocator = ManualPotholeLocator()

    init(
        locationService: LocationServicing,
        privacyZoneStore: PrivacyZoneStoring,
        potholeActionStore: PotholeActionStore,
        sensorCoordinator: SensorCoordinator,
        haptics: HapticsServicing,
        logger: RoadSenseLogger
    ) {
        self.locationService = locationService
        self.privacyZoneStore = privacyZoneStore
        self.potholeActionStore = potholeActionStore
        self.sensorCoordinator = sensorCoordinator
        self.haptics = haptics
        self.logger = logger
    }

    convenience init(container: AppContainer) {
        self.init(
            locationService: container.locationService,
            privacyZoneStore: container.privacyZoneStore,
            potholeActionStore: container.potholeActionStore,
            sensorCoordinator: container.sensorCoordinator,
            haptics: container.haptics,
            logger: container.logger
        )
    }

    func report(now: Date = Date()) -> PotholeActionSubmissionResult {
        do {
            try potholeActionStore.promoteExpiredPendingUndoActions(now: now)
        } catch {
            logger.error("failed to promote pending pothole actions: \(error.localizedDescription)")
        }

        let reactionSample = potholeLocator.locate(
            tapTimestamp: now,
            recentSamples: locationService.recentSamples,
            latestSample: locationService.latestSample
        )

        guard let chosenSample = usableSample(preferred: reactionSample, now: now) else {
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
            haptics.notification(.success)
            return .queued(action.id)
        } catch {
            logger.error("failed to queue pothole report: \(error.localizedDescription)")
            haptics.notification(.warning)
            return .unavailableLocation
        }
    }

    private func isUsable(_ sample: LocationSample, now: Date) -> Bool {
        let ageSeconds = now.timeIntervalSince1970 - sample.timestamp
        return ageSeconds <= 10 && sample.horizontalAccuracyMeters <= 25
    }

    private func usableSample(preferred: LocationSample?, now: Date) -> LocationSample? {
        if let preferred, isUsable(preferred, now: now) {
            return preferred
        }

        return ([locationService.latestSample].compactMap { $0 } + locationService.recentSamples)
            .filter { isUsable($0, now: now) }
            .max { $0.timestamp < $1.timestamp }
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
}
