import CoreLocation
import Foundation
import SwiftData

private enum TestingScenario: String {
    case defaultState = "default"
    case readyShell = "ready-shell"
    /// App Store screenshots: a week of sealed, already-uploaded Halifax
    /// drives so Stats and Drives look like real use. Local only; the testing
    /// API client is read-only (`TestingNetworkGuard`).
    case screenshot = "screenshot"
}

@MainActor
private struct TestingPermissionManager: PermissionManaging {
    func currentSnapshot(privacyZones: PrivacyZoneSetupState) -> PermissionSnapshot {
        PermissionSnapshot(
            location: .always,
            motion: .authorized,
            privacyZones: privacyZones
        )
    }

    func requestInitialPermissions(privacyZones: PrivacyZoneSetupState) async -> PermissionSnapshot {
        currentSnapshot(privacyZones: privacyZones)
    }
}

@MainActor
private struct TestingLocationService: LocationServicing {
    var authorizationStatus: CLAuthorizationStatus { .authorizedAlways }
    var latestSample: LocationSample? { nil }
    var recentSamples: [LocationSample] { [] }
    func makeSampleStream() -> AsyncStream<LocationSample> { AsyncStream { _ in } }
    func startPassiveMonitoring() {}
    func stopPassiveMonitoring() {}
    func start() throws {}
    func stop() {}
    func requestAlwaysUpgrade() {}
}

@MainActor
private struct TestingMotionService: MotionServicing {
    func makeSampleStream() -> AsyncStream<MotionSample> { AsyncStream { _ in } }
    func start(hz: Double) throws {}
    func stop() {}
}

@MainActor
private struct TestingDrivingDetector: DrivingDetecting {
    func makeEventStream() -> AsyncStream<Bool> { AsyncStream { _ in } }
    func start() {}
    func stop() {}
}

@MainActor
extension AppContainer {
    static func bootstrapForTesting(config: AppConfig) -> AppContainer {
        let scenario = TestingScenario(
            rawValue: ProcessInfo.processInfo.environment["ROAD_SENSE_TEST_SCENARIO"] ?? TestingScenario.defaultState.rawValue
        ) ?? .defaultState
        let logger = RoadSenseLogger.app
        let modelContainer: ModelContainer
        do {
            modelContainer = try ModelContainerProvider.makeInMemory()
        } catch {
            fatalError("Unable to create in-memory model container: \(error.localizedDescription)")
        }

        let privacyZoneStore = PrivacyZoneStore(container: modelContainer)
        let potholeActionStore = PotholeActionStore(container: modelContainer)
        let potholePhotoStore = PotholePhotoStore(container: modelContainer)
        let readingStore = ReadingStore(container: modelContainer)
        let userStatsStore = UserStatsStore(container: modelContainer)
        let uploadQueueStore = UploadQueueStore(container: modelContainer)
        // Read-only: UI tests and screenshot launches must never write seeded
        // readings, potholes or feedback to the (production) API.
        let apiClient = APIClient(
            endpoints: Endpoints(config: config),
            session: TestingNetworkGuard.makeReadOnlySession()
        )
        let locationService = TestingLocationService()
        let motionService = TestingMotionService()
        let drivingDetector = TestingDrivingDetector()
        let thermalMonitor = ThermalMonitor()
        let checkpointStore = SensorCheckpointStore()
        let uploader = Uploader(
            container: modelContainer,
            potholeActionStore: potholeActionStore,
            potholePhotoStore: potholePhotoStore,
            queueStore: uploadQueueStore,
            client: apiClient,
            logger: .upload
        )
        let uploadDrainCoordinator = UploadDrainCoordinator(
            uploader: uploader,
            logger: .upload
        )

        seedTestingScenario(
            scenario: scenario,
            container: modelContainer,
            privacyZoneStore: privacyZoneStore
        )

        return AppContainer(
            config: config,
            permissions: TestingPermissionManager(),
            modelContainer: modelContainer,
            privacyZoneStore: privacyZoneStore,
            potholeActionStore: potholeActionStore,
            potholePhotoStore: potholePhotoStore,
            readingStore: readingStore,
            userStatsStore: userStatsStore,
            uploadQueueStore: uploadQueueStore,
            apiClient: apiClient,
            uploader: uploader,
            uploadDrainCoordinator: uploadDrainCoordinator,
            sensorCoordinator: SensorCoordinator(
                locationService: locationService,
                motionService: motionService,
                drivingDetector: drivingDetector,
                thermalMonitor: thermalMonitor,
                privacyZoneStore: privacyZoneStore,
                readingStore: readingStore,
                logger: logger,
                checkpointStore: checkpointStore,
                scheduleUploadDrain: { _ in }
            ),
            locationService: locationService,
            motionService: motionService,
            drivingDetector: drivingDetector,
            thermalMonitor: thermalMonitor,
            haptics: NoOpHaptics(),
            logger: logger
        )
    }

    private static func seedTestingScenario(
        scenario: TestingScenario,
        container: ModelContainer,
        privacyZoneStore: PrivacyZoneStore
    ) {
        if scenario == .screenshot {
            seedScreenshotScenario(container: container, privacyZoneStore: privacyZoneStore)
            return
        }
        guard scenario == .readyShell else { return }

        do {
            try privacyZoneStore.save(
                label: "Home",
                latitude: 44.6488,
                longitude: -63.5752,
                radiusM: 300
            )

            let context = ModelContext(container)
            // Relative to now so the launch retention sweep (30 days) keeps
            // the seeded rows.
            let baseTime = Date().addingTimeInterval(-60 * 60)

            context.insert(
                ReadingRecord(
                    latitude: 44.6488,
                    longitude: -63.5752,
                    roughnessRMS: 1.05,
                    speedKMH: 46,
                    heading: 180,
                    gpsAccuracyM: 4,
                    isPothole: false,
                    potholeMagnitude: nil,
                    recordedAt: baseTime
                )
            )
            context.insert(
                ReadingRecord(
                    latitude: 44.6491,
                    longitude: -63.5750,
                    roughnessRMS: 1.18,
                    speedKMH: 51,
                    heading: 180,
                    gpsAccuracyM: 5,
                    isPothole: true,
                    potholeMagnitude: 2.7,
                    recordedAt: baseTime.addingTimeInterval(12)
                )
            )
            context.insert(
                ReadingRecord(
                    latitude: 44.6494,
                    longitude: -63.5748,
                    roughnessRMS: 0.0,
                    speedKMH: 18,
                    heading: 180,
                    gpsAccuracyM: 5,
                    isPothole: false,
                    potholeMagnitude: nil,
                    recordedAt: baseTime.addingTimeInterval(24),
                    droppedByPrivacyZone: true
                )
            )
            context.insert(
                UserStats(
                    totalKmRecorded: 2.4,
                    totalSegmentsContributed: 7,
                    lastDriveAt: baseTime.addingTimeInterval(12),
                    potholesReported: 1
                )
            )
            try context.save()
        } catch {
            fatalError("Unable to seed UI test scenario: \(error.localizedDescription)")
        }
    }

    private static func seedScreenshotScenario(
        container: ModelContainer,
        privacyZoneStore: PrivacyZoneStore
    ) {
        // Halifax routes as waypoint lists (lat, lng). Readings are spaced
        // about 2 s apart at the drive's speed, as the real pipeline does.
        let routes: [(waypoints: [(Double, Double)], daysAgo: Double, speedKMH: Double)] = [
            ([(44.6519, -63.5822), (44.6573, -63.5937), (44.6624, -63.6090), (44.6700, -63.6225), (44.6866, -63.6516)], 6.3, 52),
            ([(44.6466, -63.5732), (44.6440, -63.5826), (44.6372, -63.5911), (44.6271, -63.6105), (44.6180, -63.6240)], 4.2, 44),
            ([(44.6574, -63.5869), (44.6650, -63.5710), (44.6702, -63.5576), (44.6806, -63.5440), (44.6960, -63.5310)], 2.4, 58),
            ([(44.6486, -63.5755), (44.6553, -63.5807), (44.6621, -63.5862), (44.6705, -63.5960), (44.6812, -63.6122)], 0.9, 47),
        ]

        do {
            try privacyZoneStore.save(label: "Home", latitude: 44.6488, longitude: -63.5752, radiusM: 300)
            let context = ModelContext(container)
            var totalKm = 0.0
            var lastDriveAt: Date?

            for (routeIndex, route) in routes.enumerated() {
                let start = Date().addingTimeInterval(-route.daysAgo * 86_400)
                let metresPerReading = route.speedKMH / 3.6 * 2
                var points: [(Double, Double)] = []
                for (a, b) in zip(route.waypoints, route.waypoints.dropFirst()) {
                    let legMetres = haversineMetres(a, b)
                    let steps = max(1, Int(legMetres / metresPerReading))
                    for step in 0..<steps {
                        let t = Double(step) / Double(steps)
                        points.append((a.0 + (b.0 - a.0) * t, a.1 + (b.1 - a.1) * t))
                    }
                    totalKm += legMetres / 1000
                }

                let session = DriveSessionRecord(
                    startedAt: start,
                    endedAt: start.addingTimeInterval(Double(points.count) * 2),
                    startLatitude: points.first?.0 ?? 44.6488,
                    startLongitude: points.first?.1 ?? -63.5752,
                    endLatitude: points.last?.0,
                    endLongitude: points.last?.1,
                    isSealed: true
                )
                context.insert(session)

                for (i, point) in points.enumerated() {
                    let recordedAt = start.addingTimeInterval(Double(i) * 2)
                    // The first samples of the drive that starts near Home fall inside the zone.
                    let inHomeZone = routeIndex == 1 && i < 9
                    let wave = (sin(Double(i) / 7) + 1) / 2
                    context.insert(
                        ReadingRecord(
                            latitude: point.0,
                            longitude: point.1,
                            roughnessRMS: 0.35 + wave * 0.9 + (i % 41 == 0 ? 1.4 : 0),
                            speedKMH: route.speedKMH,
                            heading: 0,
                            gpsAccuracyM: 5,
                            isPothole: i % 97 == 50,
                            potholeMagnitude: i % 97 == 50 ? 2.6 : nil,
                            recordedAt: recordedAt,
                            driveSessionID: session.id,
                            uploadedAt: inHomeZone ? nil : recordedAt.addingTimeInterval(600),
                            uploadReadyAt: recordedAt,
                            droppedByPrivacyZone: inHomeZone
                        )
                    )
                }
                lastDriveAt = session.endedAt
            }

            context.insert(
                UserStats(
                    totalKmRecorded: (totalKm * 10).rounded() / 10,
                    totalSegmentsContributed: 0,
                    lastDriveAt: lastDriveAt,
                    potholesReported: 2
                )
            )
            try context.save()
        } catch {
            fatalError("Unable to seed screenshot scenario: \(error.localizedDescription)")
        }
    }

    private static func haversineMetres(_ a: (Double, Double), _ b: (Double, Double)) -> Double {
        let r = 6_371_000.0
        let dLat = (b.0 - a.0) * .pi / 180
        let dLng = (b.1 - a.1) * .pi / 180
        let h = sin(dLat / 2) * sin(dLat / 2)
            + cos(a.0 * .pi / 180) * cos(b.0 * .pi / 180) * sin(dLng / 2) * sin(dLng / 2)
        return 2 * r * asin(min(1, sqrt(h)))
    }
}
