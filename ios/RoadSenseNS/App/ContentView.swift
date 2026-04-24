import CoreLocation
import SwiftUI
import UIKit

struct ContentView: View {
    @State private var model: AppModel
    @Environment(\.scenePhase) private var scenePhase
    @State private var isShowingPrivacyZones = false
    @State private var isShowingStats = false
    @State private var isShowingSettings = false
    @State private var lastForegroundDrainAt: Date?

    init(container: AppContainer) {
        _model = State(
            initialValue: AppModel(
                container: container,
                defaults: AppBootstrap.defaultsForCurrentProcess()
            )
        )
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
                    StatsView(statsStore: model.userStatsStore)
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
                        }
                    )
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

    private var readyShell: some View {
        MapScreen(
            model: model,
            onShowStats: {
                isShowingStats = true
            },
            onShowSettings: {
                isShowingSettings = true
            },
            onShowPrivacyZones: {
                isShowingPrivacyZones = true
            }
        )
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
        logger: .app
    )
}
