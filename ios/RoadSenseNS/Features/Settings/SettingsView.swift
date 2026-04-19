import SwiftUI

struct SettingsView: View {
    @Bindable var model: AppModel
    let onManagePrivacyZones: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var isDeleting = false
    @State private var errorMessage: String?

    var body: some View {
        List {
            Section("Collection") {
                LabeledContent("Passive monitoring", value: model.isPassiveMonitoringEnabled ? "Enabled" : "Disabled")
                LabeledContent("Background collection", value: model.readiness.backgroundCollection.displayName)

                Button(model.isPassiveMonitoringEnabled ? "Stop passive monitoring" : "Start passive monitoring") {
                    if model.isPassiveMonitoringEnabled {
                        model.stopPassiveMonitoring()
                    } else {
                        model.startPassiveMonitoring()
                    }
                }
                .accessibilityIdentifier("settings.toggle-monitoring")

                if model.readiness.backgroundCollection == .upgradeRequired {
                    Button("Enable background collection") {
                        model.requestAlwaysLocationUpgrade()
                    }
                    .accessibilityIdentifier("settings.enable-background")
                }
            }

            Section("Privacy") {
                Button("Manage privacy zones") {
                    dismiss()
                    onManagePrivacyZones()
                }
                .accessibilityIdentifier("settings.manage-privacy-zones")

                Text("Privacy zones are enforced on-device. Filtered readings never leave your phone.")
                    .foregroundStyle(.secondary)
            }

            Section("Data management") {
                Button(role: .destructive) {
                    deleteLocalData()
                } label: {
                    if isDeleting {
                        ProgressView()
                    } else {
                        Text("Delete local contribution data")
                    }
                }
                .disabled(isDeleting)
                .accessibilityIdentifier("settings.delete-local-data")

                Text("This clears locally stored readings, upload queue state, and stats. It does not remove your privacy zones.")
                    .foregroundStyle(.secondary)
            }

            Section("About") {
                Text("RoadSense NS passively measures road roughness while you drive and uploads only accepted readings after privacy filtering.")
                Text("Background collection improves continuity, but it requires Always Location and can be turned off at any time.")
            }

            if let errorMessage {
                Section {
                    Text(errorMessage)
                        .foregroundStyle(.red)
                }
            }
        }
        .navigationTitle("Settings")
    }

    private func deleteLocalData() {
        isDeleting = true
        defer { isDeleting = false }

        do {
            try model.deleteLocalContributionData()
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
