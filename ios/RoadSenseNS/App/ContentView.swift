import SwiftUI

struct ContentView: View {
    @State private var model: AppModel

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

            if model.readiness.showsPrivacyRiskWarning {
                Text("Privacy zones are still skipped. Configure them before real field testing.")
                    .foregroundStyle(.orange)
            }

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
            )
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
