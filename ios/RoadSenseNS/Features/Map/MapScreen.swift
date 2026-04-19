import SwiftUI

struct MapScreen: View {
    @Bindable var model: AppModel

    let onShowStats: () -> Void
    let onShowSettings: () -> Void
    let onShowPrivacyZones: () -> Void

    @State private var isLegendExpanded = false
    @State private var selectedSegment: SegmentDetailResponse?
    @State private var isLoadingSegment = false
    @State private var segmentLoadError: String?

    var body: some View {
        ZStack {
            RoadQualityMapView(
                config: model.config,
                pendingDriveCoordinates: model.pendingDriveCoordinates,
                onSelectSegment: { segmentID in
                    Task {
                        await loadSegment(id: segmentID)
                    }
                },
                onClearSelection: {
                    selectedSegment = nil
                    segmentLoadError = nil
                }
            )

            VStack(spacing: 0) {
                topChrome
                    .padding(.horizontal, 16)
                    .padding(.top, 12)

                Spacer()

                centerState
                    .padding(.horizontal, 20)

                Spacer()

                bottomChrome
                    .padding(.horizontal, 16)
                    .padding(.bottom, 16)
            }
        }
        .sheet(item: $selectedSegment) { segment in
            SegmentDetailSheet(segment: segment)
        }
        .alert("Could not load road details", isPresented: Binding(
            get: { segmentLoadError != nil },
            set: { newValue in
                if !newValue {
                    segmentLoadError = nil
                }
            }
        )) {
            Button("OK", role: .cancel) {
                segmentLoadError = nil
            }
        } message: {
            Text(segmentLoadError ?? "Try again in a moment.")
        }
    }

    private var topChrome: some View {
        HStack(alignment: .top, spacing: 12) {
            StatusPill(
                title: recordingTitle,
                subtitle: recordingSubtitle,
                tint: recordingTint
            )

            Spacer(minLength: 12)

            HStack(spacing: 10) {
                overlayButton(systemName: "chart.bar.fill", action: onShowStats)
                overlayButton(systemName: "gearshape.fill", action: onShowSettings)
            }
        }
    }

    private var centerState: some View {
        VStack(spacing: 16) {
            Spacer(minLength: 0)

            Text("Road quality map")
                .font(.title3.weight(.semibold))
                .foregroundStyle(.white)

            Text(centerMessage)
                .font(.subheadline)
                .multilineTextAlignment(.center)
                .foregroundStyle(.white.opacity(0.82))
                .frame(maxWidth: 320)

            if model.pendingUploadCount > 0 {
                Label("\(model.pendingUploadCount) uploads waiting", systemImage: "arrow.triangle.2.circlepath")
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(.white.opacity(0.92))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(.white.opacity(0.14), in: Capsule())
            }

            if isLoadingSegment {
                ProgressView("Loading road details…")
                    .progressViewStyle(.circular)
                    .tint(.white)
                    .foregroundStyle(.white.opacity(0.9))
            }

            Spacer(minLength: 0)
        }
    }

    private var bottomChrome: some View {
        VStack(alignment: .leading, spacing: 12) {
            RoadLegendCard(isExpanded: $isLegendExpanded)
            ContributionCard(
                title: "Your contribution",
                distanceText: contributionDistanceText,
                pendingText: pendingUploadsText,
                secondaryText: secondaryContributionText,
                actionTitle: primaryActionTitle,
                onAction: handlePrimaryAction
            )
        }
    }

    private var recordingTitle: String {
        if model.readiness.backgroundCollection == .upgradeRequired {
            return "Needs Always Location"
        }
        return model.isPassiveMonitoringEnabled ? "Recording" : "Paused"
    }

    private var recordingSubtitle: String {
        if model.readiness.backgroundCollection == .upgradeRequired {
            return "Enable background collection for passive drives."
        }
        return model.isPassiveMonitoringEnabled
            ? "Tracking only while the app thinks you're driving."
            : "Passive monitoring is off until you resume it."
    }

    private var recordingTint: Color {
        if model.readiness.backgroundCollection == .upgradeRequired {
            return .orange
        }
        return model.isPassiveMonitoringEnabled ? .mint : .white.opacity(0.8)
    }

    private var centerMessage: String {
        if model.readiness.showsPrivacyRiskWarning {
            return "Finish privacy zones before real field testing so home and work areas stay off the map."
        }
        if !model.isPassiveMonitoringEnabled {
            return "Turn passive monitoring back on, then RoadSense NS will start collecting automatically the next time you drive."
        }
        if !model.pendingDriveCoordinates.isEmpty {
            return "Showing your local drive overlay. Upload to blend it into the community road-quality layer."
        }
        if model.userStatsSummary.acceptedReadingCount == 0 {
            return "Drive with RoadSense on to start mapping this area. Your first uploads will appear here after the next successful sync."
        }
        return "Community road quality layers plug into this surface next. The collection and upload path behind it is already live."
    }

    private var contributionDistanceText: String {
        let kilometers = model.userStatsSummary.totalKmRecorded
        if kilometers < 0.05 {
            return "No mapped distance yet"
        }
        return "\(kilometers.formatted(.number.precision(.fractionLength(1)))) km mapped"
    }

    private var pendingUploadsText: String {
        model.pendingUploadCount == 0
            ? "All uploads delivered"
            : "\(model.pendingUploadCount) uploads waiting"
    }

    private var secondaryContributionText: String {
        if let lastDriveAt = model.userStatsSummary.lastDriveAt {
            let formatter = RelativeDateTimeFormatter()
            formatter.unitsStyle = .short
            return "Last drive \(formatter.localizedString(for: lastDriveAt, relativeTo: .now))"
        }
        return "Segments helped: \(model.userStatsSummary.totalSegmentsContributed)"
    }

    private var primaryActionTitle: String {
        if model.readiness.showsPrivacyRiskWarning {
            return "Set privacy zones"
        }
        if model.readiness.backgroundCollection == .upgradeRequired {
            return "Enable background collection"
        }
        if !model.isPassiveMonitoringEnabled {
            return "Resume monitoring"
        }
        if model.pendingUploadCount > 0 {
            return "Upload now"
        }
        return "View stats"
    }

    private func handlePrimaryAction() {
        if model.readiness.showsPrivacyRiskWarning {
            onShowPrivacyZones()
        } else if model.readiness.backgroundCollection == .upgradeRequired {
            model.requestAlwaysLocationUpgrade()
        } else if !model.isPassiveMonitoringEnabled {
            model.startPassiveMonitoring()
        } else if model.pendingUploadCount > 0 {
            Task {
                await model.uploadPendingData()
            }
        } else {
            onShowStats()
        }
    }

    private func overlayButton(systemName: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 44, height: 44)
                .background(.black.opacity(0.26), in: Circle())
                .overlay(
                    Circle()
                        .strokeBorder(.white.opacity(0.14), lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
    }

    private func loadSegment(id: UUID) async {
        guard !isLoadingSegment else { return }

        isLoadingSegment = true
        segmentLoadError = nil

        do {
            try await Task.sleep(for: .milliseconds(140))
            let detail = try await model.fetchSegmentDetail(id: id)
            selectedSegment = detail
        } catch {
            selectedSegment = nil
            segmentLoadError = error.localizedDescription
        }

        isLoadingSegment = false
    }
}

private struct StatusPill: View {
    let title: String
    let subtitle: String
    let tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Circle()
                    .fill(tint)
                    .frame(width: 10, height: 10)

                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)
            }

            Text(subtitle)
                .font(.caption)
                .foregroundStyle(.white.opacity(0.78))
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(maxWidth: 230, alignment: .leading)
        .background(.black.opacity(0.34), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(.white.opacity(0.12), lineWidth: 1)
        )
    }
}

private struct RoadLegendCard: View {
    @Binding var isExpanded: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    isExpanded.toggle()
                }
            } label: {
                HStack(spacing: 10) {
                    Text("Road quality")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.white)

                    Spacer()

                    Image(systemName: isExpanded ? "chevron.down" : "chevron.up")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.white.opacity(0.78))
                }
            }
            .buttonStyle(.plain)

            if isExpanded {
                VStack(alignment: .leading, spacing: 8) {
                    legendRow(color: Color(roadsenseHex: 0x2CB67D), label: "Smooth")
                    legendRow(color: Color(roadsenseHex: 0xF4D35E), label: "Fair")
                    legendRow(color: Color(roadsenseHex: 0xF28C28), label: "Rough")
                    legendRow(color: Color(roadsenseHex: 0xD64550), label: "Very rough")

                    Text("Confidence explains how much community data is behind a score.")
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.72))
                }
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .padding(14)
        .background(.black.opacity(0.3), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(.white.opacity(0.1), lineWidth: 1)
        )
    }

    private func legendRow(color: Color, label: String) -> some View {
        HStack(spacing: 10) {
            Capsule()
                .fill(color)
                .frame(width: 28, height: 8)

            Text(label)
                .font(.caption.weight(.medium))
                .foregroundStyle(.white.opacity(0.88))
        }
    }
}

private struct ContributionCard: View {
    let title: String
    let distanceText: String
    let pendingText: String
    let secondaryText: String
    let actionTitle: String
    let onAction: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(title.uppercased())
                .font(.caption.weight(.bold))
                .foregroundStyle(.white.opacity(0.72))

            VStack(alignment: .leading, spacing: 6) {
                Text(distanceText)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.white)

                Text(pendingText)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.white.opacity(0.84))

                Text(secondaryText)
                    .font(.footnote)
                    .foregroundStyle(.white.opacity(0.68))
            }

            Button(actionTitle, action: onAction)
                .buttonStyle(.borderedProminent)
                .tint(Color(roadsenseHex: 0x2CB67D))
        }
        .padding(18)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .strokeBorder(.white.opacity(0.14), lineWidth: 1)
        )
    }
}

#Preview("Map Screen") {
    NavigationStack {
        MapScreen(
            model: AppModel(container: makePreviewContainer()),
            onShowStats: {},
            onShowSettings: {},
            onShowPrivacyZones: {}
        )
    }
}
