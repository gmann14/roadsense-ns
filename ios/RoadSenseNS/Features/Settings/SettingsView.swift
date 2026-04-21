import SwiftUI

struct SettingsView: View {
    @Bindable var model: AppModel
    let onManagePrivacyZones: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var isDeleting = false
    @State private var isConfirmingDelete = false
    @State private var errorMessage: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DesignTokens.Space.xl) {
                collectionCard
                privacyCard
                dataCard
                aboutCard

                if let errorMessage {
                    Text(errorMessage)
                        .font(.system(size: 14))
                        .foregroundStyle(DesignTokens.Palette.danger)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, DesignTokens.Space.xl)
            .padding(.top, DesignTokens.Space.lg)
            .padding(.bottom, DesignTokens.Space.xxxl)
        }
        .background(backgroundGradient.ignoresSafeArea())
        .navigationTitle("Settings")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Done") { dismiss() }
                    .accessibilityIdentifier("settings.close")
            }
        }
        .confirmationDialog(
            "Delete local contribution data?",
            isPresented: $isConfirmingDelete,
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) { deleteLocalData() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This clears locally stored readings, upload queue state, and stats. It does not touch your privacy zones.")
        }
    }

    private var backgroundGradient: some View {
        LinearGradient(
            colors: [DesignTokens.Palette.canvas, DesignTokens.Palette.canvasSunken],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    // MARK: - Cards

    private var collectionCard: some View {
        groupedCard(
            iconSystemName: "waveform.path.ecg",
            iconTint: DesignTokens.Palette.deep,
            title: "Collection",
            subtitle: "Passive monitoring starts when permissions are in place."
        ) {
            VStack(spacing: 0) {
                statusRow(
                    label: "Passive monitoring",
                    value: model.isPassiveMonitoringEnabled ? "Enabled" : "Disabled",
                    valueTint: model.isPassiveMonitoringEnabled ? DesignTokens.Palette.smooth : DesignTokens.Palette.inkMuted
                )
                Divider()
                statusRow(
                    label: "Background collection",
                    value: model.readiness.backgroundCollection.displayName,
                    valueTint: DesignTokens.Palette.inkMuted
                )
            }
            .background(DesignTokens.Palette.canvasSunken, in: RoundedRectangle(cornerRadius: DesignTokens.Radius.sm, style: .continuous))

            Button {
                if model.isPassiveMonitoringEnabled {
                    model.stopPassiveMonitoring()
                } else {
                    model.startPassiveMonitoring()
                }
            } label: {
                Text(model.isPassiveMonitoringEnabled ? "Stop passive monitoring" : "Start passive monitoring")
                    .font(.system(size: 16, weight: .semibold))
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(model.isPassiveMonitoringEnabled ? DesignTokens.Palette.warning : DesignTokens.Palette.deep)
            .controlSize(.large)
            .accessibilityIdentifier("settings.toggle-monitoring")

            if model.readiness.backgroundCollection == .upgradeRequired {
                Button("Enable background collection") {
                    model.requestAlwaysLocationUpgrade()
                }
                .buttonStyle(.bordered)
                .tint(DesignTokens.Palette.deep)
                .controlSize(.large)
                .frame(maxWidth: .infinity)
                .accessibilityIdentifier("settings.enable-background")
            }
        }
    }

    private var privacyCard: some View {
        groupedCard(
            iconSystemName: "lock.shield.fill",
            iconTint: DesignTokens.Palette.smooth,
            title: "Privacy",
            subtitle: "Zones filter readings on-device before upload. Home, work, partner, school — as many as you need."
        ) {
            Button("Manage privacy zones") {
                dismiss()
                onManagePrivacyZones()
            }
            .buttonStyle(.borderedProminent)
            .tint(DesignTokens.Palette.deep)
            .controlSize(.large)
            .frame(maxWidth: .infinity)
            .accessibilityIdentifier("settings.manage-privacy-zones")
        }
    }

    private var dataCard: some View {
        groupedCard(
            iconSystemName: "trash.circle.fill",
            iconTint: DesignTokens.Palette.warning,
            title: "Data management",
            subtitle: "Locally stored readings, upload queue state, and stats only. Privacy zones stay in place."
        ) {
            Button {
                isConfirmingDelete = true
            } label: {
                HStack {
                    if isDeleting {
                        ProgressView()
                            .tint(DesignTokens.Palette.danger)
                    }
                    Text(isDeleting ? "Deleting…" : "Delete local contribution data")
                        .font(.system(size: 16, weight: .semibold))
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .tint(DesignTokens.Palette.danger)
            .controlSize(.large)
            .disabled(isDeleting)
            .accessibilityIdentifier("settings.delete-local-data")
        }
    }

    private var aboutCard: some View {
        groupedCard(
            iconSystemName: "info.circle.fill",
            iconTint: DesignTokens.Palette.inkMuted,
            title: "About",
            subtitle: nil
        ) {
            VStack(alignment: .leading, spacing: DesignTokens.Space.sm) {
                Text("RoadSense NS passively measures road roughness while you drive and uploads only accepted readings after privacy filtering.")
                Text("Background collection improves continuity, but it requires Always Location and can be turned off at any time.")
            }
            .font(.system(size: 14))
            .foregroundStyle(DesignTokens.Palette.inkMuted)
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Shared building blocks

    @ViewBuilder
    private func groupedCard<Content: View>(
        iconSystemName: String,
        iconTint: Color,
        title: String,
        subtitle: String?,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: DesignTokens.Space.md) {
            HStack(spacing: DesignTokens.Space.sm) {
                ZStack {
                    Circle()
                        .fill(iconTint.opacity(0.14))
                        .frame(width: 36, height: 36)
                    Image(systemName: iconSystemName)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(iconTint)
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: 18, weight: .semibold, design: .rounded))
                        .foregroundStyle(DesignTokens.Palette.ink)

                    if let subtitle {
                        Text(subtitle)
                            .font(.system(size: 13))
                            .foregroundStyle(DesignTokens.Palette.inkMuted)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }

            VStack(alignment: .leading, spacing: DesignTokens.Space.sm) {
                content()
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(DesignTokens.Space.lg)
        .background(DesignTokens.Palette.surface, in: RoundedRectangle(cornerRadius: DesignTokens.Radius.md, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: DesignTokens.Radius.md, style: .continuous)
                .strokeBorder(DesignTokens.Palette.border, lineWidth: 1)
        )
    }

    private func statusRow(label: String, value: String, valueTint: Color) -> some View {
        HStack {
            Text(label)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(DesignTokens.Palette.ink)
            Spacer()
            Text(value)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(valueTint)
        }
        .padding(.horizontal, DesignTokens.Space.md)
        .padding(.vertical, DesignTokens.Space.sm)
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
