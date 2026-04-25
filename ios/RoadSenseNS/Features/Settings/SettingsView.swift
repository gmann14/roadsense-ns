import SwiftUI

struct SettingsView: View {
    @Bindable var model: AppModel
    let onManagePrivacyZones: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var isDeleting = false
    @State private var isRetryingFailedUploads = false
    @State private var isRetryingFailedPotholeActions = false
    @State private var isRetryingFailedPhotos = false
    @State private var isConfirmingDelete = false
    @State private var errorMessage: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DesignTokens.Space.xl) {
                collectionCard
                uploadsCard
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
            Text("This clears locally stored readings, pothole reports, upload queue state, and stats. It does not touch your privacy zones.")
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
            subtitle: "Collection is your on/off switch. Background use lets RoadSense keep collecting after you leave the app."
        ) {
            VStack(spacing: 0) {
                statusRow(
                    label: "Collection",
                    value: model.isPassiveMonitoringEnabled ? "Enabled" : "Disabled",
                    valueTint: model.isPassiveMonitoringEnabled ? DesignTokens.Palette.smooth : DesignTokens.Palette.inkMuted
                )
                Divider()
                statusRow(
                    label: "Runs in background",
                    value: model.readiness.backgroundCollection.displayName,
                    valueTint: backgroundAccessTint
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
                Text(model.isPassiveMonitoringEnabled ? "Stop collection" : "Start collection")
                    .font(.system(size: 16, weight: .semibold))
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(model.isPassiveMonitoringEnabled ? DesignTokens.Palette.warning : DesignTokens.Palette.deep)
            .controlSize(.large)
            .accessibilityIdentifier("settings.toggle-monitoring")

            if model.readiness.backgroundCollection == .upgradeRequired {
                Button("Allow in background") {
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
            subtitle: "Optional zones filter readings on-device before upload. Useful for home, work, or anywhere you stop often."
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

    private var uploadsCard: some View {
        groupedCard(
            iconSystemName: "arrow.triangle.2.circlepath.circle.fill",
            iconTint: DesignTokens.Palette.deep,
            title: "Uploads",
            subtitle: "Uploads happen automatically when a network is available."
        ) {
            VStack(spacing: 0) {
                statusRow(
                    label: "Uploads waiting",
                    value: "\(model.pendingUploadCount)",
                    valueTint: DesignTokens.Palette.ink
                )
                Divider()
                statusRow(
                    label: "Pothole marks waiting",
                    value: "\(model.potholeActionStatusSummary.pendingCount)",
                    valueTint: DesignTokens.Palette.ink
                )
                Divider()
                statusRow(
                    label: "Photo reports waiting",
                    value: "\(model.potholePhotoStatusSummary.pendingCount)",
                    valueTint: DesignTokens.Palette.ink
                )
                Divider()
                statusRow(
                    label: "Last successful upload",
                    value: formattedUploadTime(lastSuccessfulUploadAt),
                    valueTint: DesignTokens.Palette.inkMuted
                )
                Divider()
                statusRow(
                    label: "Waiting reason",
                    value: uploadWaitingReason,
                    valueTint: DesignTokens.Palette.inkMuted
                )
            }
            .background(DesignTokens.Palette.canvasSunken, in: RoundedRectangle(cornerRadius: DesignTokens.Radius.sm, style: .continuous))

            if model.uploadStatusSummary.failedPermanentBatchCount > 0 {
                Button {
                    retryFailedUploads()
                } label: {
                    HStack {
                        if isRetryingFailedUploads {
                            ProgressView()
                                .tint(DesignTokens.Palette.deep)
                        }
                        Text(isRetryingFailedUploads ? "Retrying failed batches…" : "Retry failed batches")
                            .font(.system(size: 16, weight: .semibold))
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(DesignTokens.Palette.deep)
                .controlSize(.large)
                .disabled(isRetryingFailedUploads)
                .accessibilityIdentifier("settings.retry-failed-uploads")
            }

            if model.potholeActionStatusSummary.failedPermanentCount > 0 {
                Button {
                    retryFailedPotholeActions()
                } label: {
                    HStack {
                        if isRetryingFailedPotholeActions {
                            ProgressView()
                                .tint(DesignTokens.Palette.deep)
                        }
                        Text(
                            isRetryingFailedPotholeActions
                                ? "Retrying failed pothole marks…"
                                : "Retry failed pothole marks"
                        )
                        .font(.system(size: 16, weight: .semibold))
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(DesignTokens.Palette.deep)
                .controlSize(.large)
                .disabled(isRetryingFailedPotholeActions)
                .accessibilityIdentifier("settings.retry-failed-pothole-actions")

                VStack(alignment: .leading, spacing: DesignTokens.Space.sm) {
                    Text("Failed pothole marks stay on-device until you retry them.")
                        .font(.system(size: 13))
                        .foregroundStyle(DesignTokens.Palette.inkMuted)
                        .fixedSize(horizontal: false, vertical: true)

                    ForEach(model.failedPotholeActions) { action in
                        failedPotholeActionRow(action)
                    }
                }
            }

            if model.potholePhotoStatusSummary.failedPermanentCount > 0 {
                Button {
                    retryFailedPhotos()
                } label: {
                    HStack {
                        if isRetryingFailedPhotos {
                            ProgressView()
                                .tint(DesignTokens.Palette.deep)
                        }
                        Text(isRetryingFailedPhotos ? "Retrying failed photos…" : "Retry failed photos")
                            .font(.system(size: 16, weight: .semibold))
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(DesignTokens.Palette.deep)
                .controlSize(.large)
                .disabled(isRetryingFailedPhotos)
                .accessibilityIdentifier("settings.retry-failed-photos")

                VStack(alignment: .leading, spacing: DesignTokens.Space.sm) {
                    Text("Failed photos stay on-device until you retry or remove them.")
                        .font(.system(size: 13))
                        .foregroundStyle(DesignTokens.Palette.inkMuted)
                        .fixedSize(horizontal: false, vertical: true)

                    ForEach(model.failedPotholePhotos) { photo in
                        failedPhotoRow(photo)
                    }
                }
            }
        }
    }

    private var dataCard: some View {
        groupedCard(
            iconSystemName: "trash.circle.fill",
            iconTint: DesignTokens.Palette.warning,
            title: "Data management",
            subtitle: "Locally stored readings, pothole reports, upload queue state, and stats only. Privacy zones stay in place."
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

    private func failedPhotoRow(_ photo: FailedPotholePhotoSummary) -> some View {
        VStack(alignment: .leading, spacing: DesignTokens.Space.xs) {
            Text(formattedCoordinateLabel(for: photo))
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(DesignTokens.Palette.ink)
            Text("Captured \(photo.capturedAt.formatted(date: .abbreviated, time: .shortened))\(httpStatusLabel(for: photo))")
                .font(.system(size: 13))
                .foregroundStyle(DesignTokens.Palette.inkMuted)
                .fixedSize(horizontal: false, vertical: true)

            Button("Remove photo") {
                model.deleteFailedPotholePhoto(id: photo.id)
            }
            .buttonStyle(.bordered)
            .tint(DesignTokens.Palette.warning)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(DesignTokens.Space.md)
        .background(DesignTokens.Palette.canvasSunken, in: RoundedRectangle(cornerRadius: DesignTokens.Radius.sm, style: .continuous))
    }

    private func failedPotholeActionRow(_ action: FailedPotholeActionSummary) -> some View {
        VStack(alignment: .leading, spacing: DesignTokens.Space.xs) {
            Text(formattedCoordinateLabel(for: action))
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(DesignTokens.Palette.ink)
            Text("Marked \(action.recordedAt.formatted(date: .abbreviated, time: .shortened))\(httpStatusLabel(for: action))")
                .font(.system(size: 13))
                .foregroundStyle(DesignTokens.Palette.inkMuted)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(DesignTokens.Space.md)
        .background(DesignTokens.Palette.canvasSunken, in: RoundedRectangle(cornerRadius: DesignTokens.Radius.sm, style: .continuous))
    }

    private var aboutCard: some View {
        groupedCard(
            iconSystemName: "info.circle.fill",
            iconTint: DesignTokens.Palette.inkMuted,
            title: "About",
            subtitle: nil
        ) {
            VStack(alignment: .leading, spacing: DesignTokens.Space.sm) {
                Text("RoadSense NS passively measures road roughness while you drive and uploads only accepted readings that survive endpoint trimming and privacy filtering.")
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

    private var uploadWaitingReason: String {
        if model.uploadStatusSummary.failedPermanentBatchCount > 0
            || model.potholeActionStatusSummary.failedPermanentCount > 0
            || model.potholePhotoStatusSummary.failedPermanentCount > 0 {
            return "Needs attention"
        }

        if let nextRetryAt = nextRetryAt {
            return "Retrying at \(nextRetryAt.formatted(date: .omitted, time: .shortened))"
        }

        if model.pendingUploadCount > 0 {
            return "Waiting to upload"
        }

        return "Up to date"
    }

    private var nextRetryAt: Date? {
        [
            model.uploadStatusSummary.nextRetryAt,
            model.potholeActionStatusSummary.nextRetryAt,
            model.potholePhotoStatusSummary.nextRetryAt,
        ]
        .compactMap { $0 }
        .min()
    }

    private var lastSuccessfulUploadAt: Date? {
        [
            model.uploadStatusSummary.lastSuccessfulUploadAt,
            model.potholeActionStatusSummary.lastSuccessfulUploadAt,
            model.potholePhotoStatusSummary.lastSuccessfulUploadAt,
        ]
        .compactMap { $0 }
        .max()
    }

    private var backgroundAccessTint: Color {
        switch model.readiness.backgroundCollection {
        case .enabled:
            return DesignTokens.Palette.smooth
        case .upgradeRequired:
            return DesignTokens.Palette.warning
        case .unavailable:
            return DesignTokens.Palette.inkMuted
        }
    }

    private func formattedUploadTime(_ date: Date?) -> String {
        guard let date else {
            return "Never"
        }

        return date.formatted(date: .abbreviated, time: .shortened)
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

    private func retryFailedUploads() {
        isRetryingFailedUploads = true

        Task {
            await model.retryFailedUploads()
            await MainActor.run {
                isRetryingFailedUploads = false
                errorMessage = nil
            }
        }
    }

    private func retryFailedPotholeActions() {
        isRetryingFailedPotholeActions = true

        Task {
            await model.retryFailedPotholeActions()
            await MainActor.run {
                isRetryingFailedPotholeActions = false
                errorMessage = nil
            }
        }
    }

    private func retryFailedPhotos() {
        isRetryingFailedPhotos = true

        Task {
            await model.retryFailedPotholePhotos()
            await MainActor.run {
                isRetryingFailedPhotos = false
                errorMessage = nil
            }
        }
    }

    private func formattedCoordinateLabel(for photo: FailedPotholePhotoSummary) -> String {
        formattedCoordinateLabel(latitude: photo.latitude, longitude: photo.longitude)
    }

    private func formattedCoordinateLabel(for action: FailedPotholeActionSummary) -> String {
        formattedCoordinateLabel(latitude: action.latitude, longitude: action.longitude)
    }

    private func formattedCoordinateLabel(latitude: Double, longitude: Double) -> String {
        let lat = latitude.formatted(.number.precision(.fractionLength(4)))
        let lng = longitude.formatted(.number.precision(.fractionLength(4)))
        return "Near \(lat), \(lng)"
    }

    private func httpStatusLabel(for action: FailedPotholeActionSummary) -> String {
        httpStatusLabel(action.lastHTTPStatusCode)
    }

    private func httpStatusLabel(for photo: FailedPotholePhotoSummary) -> String {
        httpStatusLabel(photo.lastHTTPStatusCode)
    }

    private func httpStatusLabel(_ statusCode: Int?) -> String {
        guard let statusCode else {
            return ""
        }

        return " · HTTP \(statusCode)"
    }
}
