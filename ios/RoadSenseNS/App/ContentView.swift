import CoreLocation
import SwiftUI
import UIKit

struct ContentView: View {
    @State private var model: AppModel
    @Environment(\.scenePhase) private var scenePhase
    @State private var isShowingPrivacyZones = false
    @State private var isShowingStats = false
    @State private var isShowingSettings = false
    @State private var isShowingDrives = false
    @State private var pendingMapTarget: DriveBoundingBox?
    @State private var feedbackComposer: FeedbackComposerModel?
    @State private var feedbackQueue: FeedbackQueue
    @State private var lastForegroundDrainAt: Date?

    init(container: AppContainer) {
        let defaults = AppBootstrap.defaultsForCurrentProcess()
        _model = State(
            initialValue: AppModel(
                container: container,
                defaults: defaults
            )
        )
        _feedbackQueue = State(initialValue: FeedbackQueue(defaults: defaults))
    }

    var body: some View {
        NavigationStack {
            Group {
                if model.readiness.stage == .ready {
                    readyShell
                        .toolbar(.hidden, for: .navigationBar)
                } else {
                    OnboardingFlowView(model: model)
                        .toolbar(.hidden, for: .navigationBar)
                }
            }
            .onChange(of: scenePhase) { _, newPhase in
                handleScenePhaseChange(newPhase)
                updateIdleTimer()
            }
            .onChange(of: model.isPassiveMonitoringEnabled) { _, _ in
                updateIdleTimer()
            }
            .sheet(isPresented: $isShowingPrivacyZones, onDismiss: {
                model.refreshPrivacyZones()
            }) {
                PrivacyZonesView(
                    store: model.privacyZoneStore,
                    onChange: {
                        model.refreshPrivacyZones()
                    }
                )
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
            }
            .sheet(isPresented: $isShowingStats) {
                NavigationStack {
                    StatsView(
                        statsStore: model.userStatsStore,
                        onAppear: { model.refreshCollectionStats() },
                        onShowDrives: { isShowingDrives = true }
                    )
                }
            }
            .sheet(isPresented: $isShowingDrives) {
                NavigationStack {
                    DrivesListView(
                        readingStore: model.readingStore,
                        mapboxAccessToken: model.config.mapboxAccessToken,
                        onOpenOnMap: { bbox in
                            pendingMapTarget = bbox
                        }
                    )
                }
            }
            .sheet(isPresented: $isShowingSettings, onDismiss: {
                model.refreshPermissions()
            }) {
                NavigationStack {
                    SettingsView(
                        model: model,
                        onManagePrivacyZones: {
                            isShowingPrivacyZones = true
                        },
                        onSendFeedback: {
                            feedbackComposer = FeedbackComposerModel(
                                submitter: FeedbackSubmissionAPIClient(apiClient: model.apiClient),
                                queue: feedbackQueue,
                                route: "Settings"
                            )
                        }
                    )
                }
            }
            .sheet(item: $feedbackComposer) { composer in
                FeedbackComposerView(model: composer)
                    .presentationDetents([.large])
                    .presentationDragIndicator(.visible)
                    .task {
                        // Drain anything queued from a prior session/network outage
                        // as soon as the composer mounts. Silent on success.
                        await composer.retryPending()
                    }
            }
        }
        .onAppear {
            updateIdleTimer()
        }
        .onDisappear {
            UIApplication.shared.isIdleTimerDisabled = false
        }
    }

    private func handleScenePhaseChange(_ newPhase: ScenePhase) {
        switch newPhase {
        case .active:
            let now = Date()
            if let lastForegroundDrainAt,
               now.timeIntervalSince(lastForegroundDrainAt) < 30 {
                return
            }

            lastForegroundDrainAt = now
            Task {
                await model.handleAppDidBecomeActive()
            }
            if feedbackQueue.pendingCount > 0 {
                let submitter = FeedbackSubmissionAPIClient(apiClient: model.apiClient)
                Task {
                    _ = await FeedbackQueueDrainer.drain(queue: feedbackQueue, submitter: submitter)
                }
            }
        case .background:
            model.handleAppDidEnterBackground()
        default:
            break
        }
    }

    private func updateIdleTimer() {
        UIApplication.shared.isIdleTimerDisabled =
            scenePhase == .active
            && model.readiness.stage == .ready
            && model.isPassiveMonitoringEnabled
    }

    @ViewBuilder
    private var readyShell: some View {
        if FeatureFlags.drivingRedesignEnabled {
            MapScreenRedesign(
                model: model,
                pendingMapTarget: $pendingMapTarget,
                onShowStats: { isShowingStats = true },
                onShowSettings: { isShowingSettings = true },
                onShowPrivacyZones: { isShowingPrivacyZones = true }
            )
        } else {
            MapScreen(
                model: model,
                pendingMapTarget: $pendingMapTarget,
                onShowStats: { isShowingStats = true },
                onShowSettings: { isShowingSettings = true },
                onShowPrivacyZones: { isShowingPrivacyZones = true }
            )
        }
    }
}

#Preview {
    ContentView(container: makePreviewContainer())
}

@MainActor
private struct PreviewPermissionManager: PermissionManaging {
    let snapshot: PermissionSnapshot

    func currentSnapshot(privacyZones: PrivacyZoneSetupState) -> PermissionSnapshot {
        PermissionSnapshot(
            location: snapshot.location,
            motion: snapshot.motion,
            privacyZones: privacyZones
        )
    }

    func requestInitialPermissions(privacyZones: PrivacyZoneSetupState) async -> PermissionSnapshot {
        currentSnapshot(privacyZones: privacyZones)
    }
}

@MainActor
private final class PreviewPrivacyZoneStore: PrivacyZoneStoring {
    func fetchAll() throws -> [PrivacyZoneRecord] { [] }
    func hasConfiguredZones() throws -> Bool { true }
    func save(label: String, latitude: Double, longitude: Double, radiusM: Double) throws {}
    func delete(id: UUID) throws {}
}

@MainActor
private struct PreviewLocationService: LocationServicing {
    var samples: AsyncStream<LocationSample> { AsyncStream { _ in } }
    var authorizationStatus: CLAuthorizationStatus { .authorizedWhenInUse }
    var latestSample: LocationSample? { nil }
    var recentSamples: [LocationSample] { [] }
    func startPassiveMonitoring() {}
    func stopPassiveMonitoring() {}
    func start() throws {}
    func stop() {}
    func requestAlwaysUpgrade() {}
}

@MainActor
private struct PreviewMotionService: MotionServicing {
    var samples: AsyncStream<MotionSample> { AsyncStream { _ in } }
    func start(hz: Double) throws {}
    func stop() {}
}

@MainActor
private struct PreviewDrivingDetector: DrivingDetecting {
    var events: AsyncStream<Bool> { AsyncStream { _ in } }
    func start() {}
    func stop() {}
}

@MainActor
func makePreviewContainer() -> AppContainer {
    let config = AppConfig(
        environment: .local,
        apiBaseURL: URL(string: "http://127.0.0.1:54321")!,
        mapboxAccessToken: "pk.preview",
        supabaseAnonKey: "anon.preview"
    )
    let modelContainer = try! ModelContainerProvider.makeDefault()
    let privacyZoneStore = PreviewPrivacyZoneStore()
    let potholeActionStore = PotholeActionStore(container: modelContainer)
    let potholePhotoStore = PotholePhotoStore(container: modelContainer)
    let readingStore = ReadingStore(container: modelContainer)
    let userStatsStore = UserStatsStore(container: modelContainer)
    let uploadQueueStore = UploadQueueStore(container: modelContainer)
    let checkpointStore = SensorCheckpointStore()
    let apiClient = APIClient(endpoints: Endpoints(config: config))
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

    return AppContainer(
        config: config,
        permissions: PreviewPermissionManager(
            snapshot: PermissionSnapshot(
                location: .whenInUse,
                motion: .authorized,
                privacyZones: .configured
            )
        ),
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
            locationService: PreviewLocationService(),
            motionService: PreviewMotionService(),
            drivingDetector: PreviewDrivingDetector(),
            thermalMonitor: ThermalMonitor(),
            privacyZoneStore: privacyZoneStore,
            readingStore: readingStore,
            logger: .app,
            checkpointStore: checkpointStore,
            scheduleUploadDrain: { _ in }
        ),
        locationService: PreviewLocationService(),
        motionService: PreviewMotionService(),
        drivingDetector: PreviewDrivingDetector(),
        thermalMonitor: ThermalMonitor(),
        haptics: NoOpHaptics(),
        logger: .app
    )
}
