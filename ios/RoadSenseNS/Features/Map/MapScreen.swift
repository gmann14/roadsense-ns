import SwiftUI

struct MapScreen: View {
    @Bindable var model: AppModel
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    let onShowStats: () -> Void
    let onShowSettings: () -> Void
    let onShowPrivacyZones: () -> Void

    @State private var isCardExpanded = true
    @State private var selectedSegment: SegmentDetailResponse?
    @State private var isLoadingSegment = false
    @State private var segmentLoadError: String?
    @State private var isMapLoaded = false
    @State private var mapLoadError: String?

    var body: some View {
        ZStack(alignment: .top) {
            RoadQualityMapView(
                config: model.config,
                pendingDriveCoordinates: model.pendingDriveCoordinates,
                onMapLoaded: {
                    isMapLoaded = true
                    mapLoadError = nil
                },
                onMapLoadingError: { message in
                    mapLoadError = message
                    isMapLoaded = false
                },
                onSelectSegment: { segmentID in
                    Task { await loadSegment(id: segmentID) }
                },
                onClearSelection: {
                    selectedSegment = nil
                    segmentLoadError = nil
                }
            )

            VStack(spacing: 0) {
                topBar
                    .padding(.horizontal, DesignTokens.Space.md)
                    .padding(.top, DesignTokens.Space.sm)

                Spacer(minLength: 0)

                if showsFirstRunIllustration {
                    firstRunIllustration
                        .transition(.opacity.combined(with: .scale(scale: 0.96)))
                }

                Spacer(minLength: 0)

                bottomCard
                    .padding(.horizontal, DesignTokens.Space.md)
                    .padding(.bottom, DesignTokens.Space.md)
            }

            if isLoadingSegment {
                loadingVeil
            }
        }
        .sheet(item: $selectedSegment) { segment in
            SegmentDetailSheet(segment: segment)
        }
        .alert("Could not load road details", isPresented: Binding(
            get: { segmentLoadError != nil },
            set: { if !$0 { segmentLoadError = nil } }
        )) {
            Button("OK", role: .cancel) { segmentLoadError = nil }
        } message: {
            Text(segmentLoadError ?? "Try again in a moment.")
        }
    }

    // MARK: - Top bar

    private var topBar: some View {
        HStack(alignment: .center, spacing: DesignTokens.Space.sm) {
            Text("RoadSense NS")
                .font(.system(size: 16, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
                .shadow(color: .black.opacity(0.35), radius: 6, y: 1)
                .accessibilityIdentifier("map.title")

            Spacer(minLength: DesignTokens.Space.sm)

            HStack(spacing: DesignTokens.Space.xs) {
                chromeButton(
                    systemName: "chart.bar.fill",
                    accessibilityID: "map.stats-button",
                    action: onShowStats
                )
                chromeButton(
                    systemName: "gearshape.fill",
                    accessibilityID: "map.settings-button",
                    action: onShowSettings
                )
            }
        }
    }

    private func chromeButton(systemName: String, accessibilityID: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 40, height: 40)
                .background(.black.opacity(0.32), in: Circle())
                .overlay(
                    Circle().strokeBorder(.white.opacity(0.14), lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(accessibilityID)
    }

    // MARK: - Bottom card

    private var bottomCard: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Space.sm) {
            cardHeader

            if isCardExpanded {
                Divider().background(Color.white.opacity(0.14))

                legendChips

                metaRow

                if let mapLoadError {
                    mapLoadBanner(message: mapLoadError)
                }

                primaryAction
            }
        }
        .padding(DesignTokens.Space.md)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: DesignTokens.Radius.lg, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: DesignTokens.Radius.lg, style: .continuous)
                .strokeBorder(.white.opacity(0.14), lineWidth: 1)
        )
        .animation(DesignTokens.Motion.standard, value: isCardExpanded)
    }

    private var cardHeader: some View {
        Button {
            withAnimation(DesignTokens.Motion.standard) {
                isCardExpanded.toggle()
            }
        } label: {
            HStack(alignment: .center, spacing: DesignTokens.Space.sm) {
                Circle()
                    .fill(recordingTint)
                    .frame(width: 10, height: 10)
                    .shadow(color: recordingTint.opacity(0.7), radius: 6)

                VStack(alignment: .leading, spacing: 2) {
                    Text(recordingTitle)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.white)

                    Text(headerSubtitle)
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.78))
                        .lineLimit(1)
                        .accessibilityIdentifier("map.pending-uploads")
                }

                Spacer(minLength: DesignTokens.Space.xs)

                Image(systemName: isCardExpanded ? "chevron.down" : "chevron.up")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.white.opacity(0.72))
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var legendChips: some View {
        HStack(spacing: DesignTokens.Space.xs) {
            legendChip(color: DesignTokens.Palette.smooth, label: "Smooth")
            legendChip(color: DesignTokens.Palette.fair, label: "Fair")
            legendChip(color: DesignTokens.Palette.rough, label: "Rough")
            legendChip(color: DesignTokens.Palette.veryRough, label: "Very rough")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func legendChip(color: Color, label: String) -> some View {
        HStack(spacing: 6) {
            Capsule()
                .fill(color)
                .frame(width: 14, height: 4)
            Text(label)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white.opacity(0.86))
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Color.black.opacity(0.22), in: Capsule())
    }

    private var metaRow: some View {
        HStack(spacing: DesignTokens.Space.sm) {
            metaCell(label: "Mapped", value: mappedValue)
            Divider().frame(height: 24).background(Color.white.opacity(0.14))
            metaCell(label: "Segments", value: segmentsValue)
            Divider().frame(height: 24).background(Color.white.opacity(0.14))
            metaCell(label: "Last drive", value: lastDriveValue)
        }
    }

    private func metaCell(label: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label.uppercased())
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(.white.opacity(0.58))
                .tracking(0.6)
            Text(value)
                .font(.system(size: 14, weight: .semibold).monospacedDigit())
                .foregroundStyle(.white)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func mapLoadBanner(message: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Label("Map load issue", systemImage: "wifi.exclamationmark")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white)
            Text(message)
                .font(.caption)
                .foregroundStyle(.white.opacity(0.82))
                .lineLimit(2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(DesignTokens.Space.sm)
        .background(DesignTokens.Palette.danger.opacity(0.42), in: RoundedRectangle(cornerRadius: DesignTokens.Radius.sm, style: .continuous))
    }

    private var primaryAction: some View {
        Button(primaryActionTitle, action: handlePrimaryAction)
            .buttonStyle(.borderedProminent)
            .tint(DesignTokens.Palette.signal)
            .controlSize(.large)
            .frame(maxWidth: .infinity)
            .accessibilityIdentifier("map.primary-action")
    }

    // MARK: - First-run illustration

    private var firstRunIllustration: some View {
        VStack(spacing: DesignTokens.Space.sm) {
            ZStack {
                Circle()
                    .strokeBorder(Color.white.opacity(0.14), style: StrokeStyle(lineWidth: 1, dash: [4, 6]))
                    .frame(width: 140, height: 140)
                Circle()
                    .fill(DesignTokens.Palette.signal.opacity(0.2))
                    .frame(width: 80, height: 80)
                Image(systemName: "car.side.fill")
                    .font(.system(size: 32, weight: .regular))
                    .foregroundStyle(.white)
            }

            Text("Drive to start mapping.")
                .font(.system(size: 16, weight: .semibold, design: .rounded))
                .foregroundStyle(.white)

            Text("Your first uploads will appear here after the next sync.")
                .font(.caption)
                .multilineTextAlignment(.center)
                .foregroundStyle(.white.opacity(0.78))
                .frame(maxWidth: 280)
        }
        .padding(DesignTokens.Space.md)
    }

    private var loadingVeil: some View {
        ProgressView("Loading road details…")
            .progressViewStyle(.circular)
            .tint(.white)
            .foregroundStyle(.white)
            .padding(DesignTokens.Space.md)
            .background(Color.black.opacity(0.45), in: RoundedRectangle(cornerRadius: DesignTokens.Radius.md, style: .continuous))
    }

    // MARK: - Derived state

    private var showsFirstRunIllustration: Bool {
        isMapLoaded
            && mapLoadError == nil
            && model.userStatsSummary.acceptedReadingCount == 0
            && model.pendingDriveCoordinates.isEmpty
            && !model.readiness.showsPrivacyRiskWarning
    }

    private var recordingTitle: String {
        if model.readiness.backgroundCollection == .upgradeRequired { return "Needs Always Location" }
        if model.readiness.showsPrivacyRiskWarning { return "Privacy zones needed" }
        return model.isPassiveMonitoringEnabled ? "Recording" : "Paused"
    }

    private var headerSubtitle: String {
        if !isMapLoaded && mapLoadError == nil { return "Loading community layer…" }
        if model.readiness.showsPrivacyRiskWarning { return "Set zones before real driving." }
        if model.pendingUploadCount > 0 { return "\(model.pendingUploadCount) uploads waiting" }
        if model.userStatsSummary.acceptedReadingCount == 0 { return "No drives yet" }
        return mappedValue + " mapped"
    }

    private var recordingTint: Color {
        if model.readiness.backgroundCollection == .upgradeRequired { return DesignTokens.Palette.warning }
        if model.readiness.showsPrivacyRiskWarning { return DesignTokens.Palette.signal }
        return model.isPassiveMonitoringEnabled ? DesignTokens.Palette.smooth : .white.opacity(0.6)
    }

    private var mappedValue: String {
        let km = model.userStatsSummary.totalKmRecorded
        if km < 0.05 { return "0 km" }
        return "\(km.formatted(.number.precision(.fractionLength(1)))) km"
    }

    private var segmentsValue: String {
        "\(model.userStatsSummary.totalSegmentsContributed)"
    }

    private var lastDriveValue: String {
        guard let lastDriveAt = model.userStatsSummary.lastDriveAt else { return "—" }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter.localizedString(for: lastDriveAt, relativeTo: .now)
    }

    private var primaryActionTitle: String {
        if model.readiness.showsPrivacyRiskWarning { return "Set privacy zones" }
        if model.readiness.backgroundCollection == .upgradeRequired { return "Enable background collection" }
        if !model.isPassiveMonitoringEnabled { return "Resume monitoring" }
        return "View stats"
    }

    private func handlePrimaryAction() {
        if model.readiness.showsPrivacyRiskWarning {
            onShowPrivacyZones()
        } else if model.readiness.backgroundCollection == .upgradeRequired {
            model.requestAlwaysLocationUpgrade()
        } else if !model.isPassiveMonitoringEnabled {
            model.startPassiveMonitoring()
        } else {
            onShowStats()
        }
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
