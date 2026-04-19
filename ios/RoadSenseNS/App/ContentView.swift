import CoreLocation
import SwiftUI

struct ContentView: View {
    @State private var model: AppModel
    @State private var isShowingPrivacyZones = false

    init(container: AppContainer) {
        _model = State(initialValue: AppModel(container: container))
    }

    var body: some View {
        NavigationStack {
            Group {
                if model.readiness.stage == .ready {
                    readyShell
                } else {
                    OnboardingFlowView(model: model)
                }
            }
            .navigationTitle("RoadSense NS")
            .sheet(isPresented: $isShowingPrivacyZones, onDismiss: {
                model.refreshPrivacyZones()
            }) {
                PrivacyZonesView(
                    store: model.privacyZoneStore,
                    onChange: {
                        model.refreshPrivacyZones()
                    }
                )
            }
        }
    }

    private var readyShell: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Collection shell")
                .font(.headline)

            LabeledContent("Environment", value: model.config.environment.displayName)
            LabeledContent("API Base", value: model.config.apiBaseURL.absoluteString)
            LabeledContent("Functions Base", value: model.config.functionsBaseURL.absoluteString)
            LabeledContent("Background collection", value: model.readiness.backgroundCollection.displayName)
            LabeledContent("Pending uploads", value: "\(model.pendingUploadCount)")

            if model.readiness.showsPrivacyRiskWarning {
                Text("Privacy zones are still skipped. Configure them before real field testing.")
                    .foregroundStyle(.orange)
            }

            Button("Manage privacy zones") {
                isShowingPrivacyZones = true
            }
            .buttonStyle(.bordered)

            Button("Upload pending data") {
                Task {
                    await model.uploadPendingData()
                }
            }
            .buttonStyle(.borderedProminent)

            Spacer()
        }
        .padding(24)
    }
}

#Preview {
    ContentView(
        container: AppContainer(
            config: AppConfig(
                environment: .local,
                apiBaseURL: URL(string: "http://127.0.0.1:54321")!,
                mapboxAccessToken: "pk.preview"
            ),
            permissions: PreviewPermissionManager(
                snapshot: PermissionSnapshot(
                    location: .whenInUse,
                    motion: .authorized,
                    privacyZones: .configured
                )
            ),
            modelContainer: try! ModelContainerProvider.makeDefault(),
            privacyZoneStore: PreviewPrivacyZoneStore(),
            uploadQueueStore: UploadQueueStore(container: try! ModelContainerProvider.makeDefault()),
            apiClient: APIClient(
                endpoints: Endpoints(
                    config: AppConfig(
                        environment: .local,
                        apiBaseURL: URL(string: "http://127.0.0.1:54321")!,
                        mapboxAccessToken: "pk.preview"
                    )
                )
            ),
            uploader: Uploader(
                container: try! ModelContainerProvider.makeDefault(),
                queueStore: UploadQueueStore(container: try! ModelContainerProvider.makeDefault()),
                client: APIClient(
                    endpoints: Endpoints(
                        config: AppConfig(
                            environment: .local,
                            apiBaseURL: URL(string: "http://127.0.0.1:54321")!,
                            mapboxAccessToken: "pk.preview"
                        )
                    )
                ),
                logger: .upload
            ),
            locationService: PreviewLocationService(),
            motionService: PreviewMotionService(),
            drivingDetector: PreviewDrivingDetector(),
            thermalMonitor: ThermalMonitor(),
            logger: .app
        )
    )
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
