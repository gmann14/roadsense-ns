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
    @State private var potholeFeedback: PotholeFeedback?
    @State private var followUpPrompt: FollowUpPrompt?
    @State private var photoCaptureContext: PotholePhotoCaptureContext?
    @State private var isShowingCamera = false
    @State private var scopedPhotoSegmentID: UUID?

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
            SegmentDetailSheet(
                segment: segment,
                onSubmitPotholeAction: { pothole, actionType in
                    model.queuePotholeFollowUp(
                        potholeReportID: pothole.id,
                        actionType: actionType
                    )
                },
                onAddPhoto: { segmentID in
                    handleTakePhotoTap(segmentID: segmentID)
                }
            )
        }
        .fullScreenCover(isPresented: $isShowingCamera) {
            if let photoCaptureContext {
                PotholeCameraFlowView(
                    coordinateLabel: photoCaptureContext.coordinateLabel,
                    onCancel: {
                        isShowingCamera = false
                    },
                    onSubmit: { data in
                        isShowingCamera = false
                        handlePhotoSubmit(data)
                    }
                )
            }
        }
        .overlay(alignment: .bottom) {
            VStack(spacing: DesignTokens.Space.sm) {
                if let followUpPrompt {
                    followUpPromptBanner(followUpPrompt)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                        .task(id: followUpPrompt.id) {
                            try? await Task.sleep(for: followUpPrompt.dismissDelay)
                            guard self.followUpPrompt?.id == followUpPrompt.id else { return }
                            withAnimation(DesignTokens.Motion.standard) {
                                self.followUpPrompt = nil
                            }
                        }
                }

                if let potholeFeedback {
                    potholeFeedbackBanner(potholeFeedback)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                        .task(id: potholeFeedback.id) {
                            try? await Task.sleep(for: potholeFeedback.dismissDelay)
                            guard self.potholeFeedback?.id == potholeFeedback.id else { return }
                            withAnimation(DesignTokens.Motion.standard) {
                                self.potholeFeedback = nil
                            }
                        }
                }
            }
            .padding(.horizontal, DesignTokens.Space.md)
            .padding(.bottom, 156)
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
                .padding(.horizontal, DesignTokens.Space.sm)
                .padding(.vertical, DesignTokens.Space.xs)
                .background(
                    LinearGradient(
                        colors: [
                            DesignTokens.Palette.deep.opacity(0.82),
                            DesignTokens.Palette.deepInk.opacity(0.72)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    in: Capsule()
                )
                .overlay(
                    Capsule()
                        .strokeBorder(.white.opacity(0.16), lineWidth: 1)
                )
                .shadow(color: .black.opacity(0.22), radius: 10, y: 4)
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

                markPotholeAction

                takePhotoAction

                primaryAction

                if model.readiness.showsPrivacyRiskWarning {
                    privacyZonesAction
                }
            }
        }
        .padding(DesignTokens.Space.md)
        .background {
            RoundedRectangle(cornerRadius: DesignTokens.Radius.lg, style: .continuous)
                .fill(.ultraThinMaterial)
                .overlay(
                    RoundedRectangle(cornerRadius: DesignTokens.Radius.lg, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [
                                    DesignTokens.Palette.deep.opacity(0.74),
                                    DesignTokens.Palette.deepInk.opacity(0.64)
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                )
        }
        .overlay(
            RoundedRectangle(cornerRadius: DesignTokens.Radius.lg, style: .continuous)
                .strokeBorder(.white.opacity(0.16), lineWidth: 1)
        )
        .shadow(color: Color.black.opacity(0.16), radius: 20, y: 10)
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
                        .foregroundStyle(DesignTokens.Palette.signalSoft.opacity(0.96))
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
                .foregroundStyle(DesignTokens.Palette.surface)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Color.black.opacity(0.3), in: Capsule())
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
                .foregroundStyle(DesignTokens.Palette.signalSoft.opacity(0.94))
                .tracking(0.6)
            Text(value)
                .font(.system(size: 14, weight: .semibold).monospacedDigit())
                .foregroundStyle(DesignTokens.Palette.surface)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func mapLoadBanner(message: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Label("Map load issue", systemImage: "wifi.exclamationmark")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white)
            Text(AppBootstrap.formatMapLoadError(message))
                .font(.caption)
                .foregroundStyle(.white.opacity(0.82))
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(DesignTokens.Space.sm)
        .background(DesignTokens.Palette.danger.opacity(0.42), in: RoundedRectangle(cornerRadius: DesignTokens.Radius.sm, style: .continuous))
    }

    private var markPotholeAction: some View {
        Button(action: handleMarkPotholeTap) {
            HStack(spacing: DesignTokens.Space.xs) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 15, weight: .bold))
                Text("Mark pothole")
                    .font(.system(size: 16, weight: .bold, design: .rounded))
                Spacer(minLength: DesignTokens.Space.xs)
                Text("One tap")
                    .font(.system(size: 12, weight: .semibold))
                    .padding(.horizontal, DesignTokens.Space.xs)
                    .padding(.vertical, 5)
                    .background(.white.opacity(0.16), in: Capsule())
            }
            .foregroundStyle(.white)
            .padding(.horizontal, DesignTokens.Space.md)
            .padding(.vertical, DesignTokens.Space.sm)
            .frame(maxWidth: .infinity)
            .background(
                LinearGradient(
                    colors: [
                        DesignTokens.Palette.warning,
                        DesignTokens.Palette.danger
                    ],
                    startPoint: .leading,
                    endPoint: .trailing
                ),
                in: RoundedRectangle(cornerRadius: DesignTokens.Radius.md, style: .continuous)
            )
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("map.mark-pothole-button")
    }

    private var takePhotoAction: some View {
        Button {
            handleTakePhotoTap()
        } label: {
            HStack(spacing: DesignTokens.Space.xs) {
                Image(systemName: "camera.viewfinder")
                    .font(.system(size: 15, weight: .bold))
                Text("Take photo")
                    .font(.system(size: 15, weight: .bold, design: .rounded))
                Spacer(minLength: DesignTokens.Space.xs)
                Text("Stopped only")
                    .font(.system(size: 12, weight: .semibold))
                    .padding(.horizontal, DesignTokens.Space.xs)
                    .padding(.vertical, 5)
                    .background(.white.opacity(0.12), in: Capsule())
            }
            .foregroundStyle(.white)
            .padding(.horizontal, DesignTokens.Space.md)
            .padding(.vertical, DesignTokens.Space.sm)
            .frame(maxWidth: .infinity)
            .background(
                RoundedRectangle(cornerRadius: DesignTokens.Radius.md, style: .continuous)
                    .fill(Color.black.opacity(0.28))
            )
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("map.take-photo-button")
    }

    private var primaryAction: some View {
        Button(primaryActionTitle, action: handlePrimaryAction)
            .buttonStyle(.borderedProminent)
            .tint(DesignTokens.Palette.signal)
            .controlSize(.large)
            .frame(maxWidth: .infinity)
            .accessibilityIdentifier("map.primary-action")
    }

    private var privacyZonesAction: some View {
        Button("Manage privacy zones", action: onShowPrivacyZones)
            .buttonStyle(.plain)
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(DesignTokens.Palette.signalSoft)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityIdentifier("map.privacy-zones-action")
    }

    private func potholeFeedbackBanner(_ feedback: PotholeFeedback) -> some View {
        HStack(alignment: .center, spacing: DesignTokens.Space.sm) {
            Image(systemName: feedback.iconName)
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(feedback.tint)

            VStack(alignment: .leading, spacing: 2) {
                Text(feedback.title)
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(.white)
                Text(feedback.message)
                    .font(.caption)
                    .foregroundStyle(DesignTokens.Palette.surface)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: DesignTokens.Space.xs)

            if let actionID = feedback.actionID {
                Button("Undo") {
                    model.undoPotholeReport(id: actionID)
                    withAnimation(DesignTokens.Motion.standard) {
                        potholeFeedback = nil
                    }
                }
                .buttonStyle(.plain)
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(DesignTokens.Palette.signalSoft)
                .padding(.horizontal, DesignTokens.Space.sm)
                .padding(.vertical, DesignTokens.Space.xs)
                .background(.white.opacity(0.12), in: Capsule())
            }
        }
        .padding(DesignTokens.Space.md)
        .background(
            RoundedRectangle(cornerRadius: DesignTokens.Radius.md, style: .continuous)
                .fill(Color.black.opacity(0.72))
                .overlay(
                    RoundedRectangle(cornerRadius: DesignTokens.Radius.md, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [
                                    DesignTokens.Palette.deep.opacity(0.76),
                                    DesignTokens.Palette.deepInk.opacity(0.74)
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                )
        )
        .overlay(
            RoundedRectangle(cornerRadius: DesignTokens.Radius.md, style: .continuous)
                .strokeBorder(.white.opacity(0.16), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.24), radius: 16, y: 8)
        .accessibilityIdentifier("map.pothole-feedback-banner")
    }

    private func followUpPromptBanner(_ prompt: FollowUpPrompt) -> some View {
        VStack(alignment: .leading, spacing: DesignTokens.Space.sm) {
            HStack(spacing: DesignTokens.Space.sm) {
                Image(systemName: "questionmark.circle.fill")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(DesignTokens.Palette.warning)

                VStack(alignment: .leading, spacing: 2) {
                    Text("Still there?")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(.white)
                    Text("You’re stopped near an active pothole marker. Want to confirm it or say it looks fixed?")
                        .font(.caption)
                        .foregroundStyle(DesignTokens.Palette.surface)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: DesignTokens.Space.xs)

                Button {
                    withAnimation(DesignTokens.Motion.standard) {
                        followUpPrompt = nil
                    }
                } label: {
                    Image(systemName: "xmark")
                        .font(.caption.bold())
                        .foregroundStyle(.white.opacity(0.7))
                }
                .buttonStyle(.plain)
            }

            HStack(spacing: DesignTokens.Space.sm) {
                Button("Still there") {
                    submitPromptFollowUp(.confirmPresent, prompt: prompt)
                }
                .buttonStyle(.borderedProminent)
                .tint(DesignTokens.Palette.signal)

                Button("Looks fixed") {
                    submitPromptFollowUp(.confirmFixed, prompt: prompt)
                }
                .buttonStyle(.bordered)
                .tint(DesignTokens.Palette.success)
            }
        }
        .padding(DesignTokens.Space.md)
        .background(
            RoundedRectangle(cornerRadius: DesignTokens.Radius.md, style: .continuous)
                .fill(Color.black.opacity(0.78))
        )
        .overlay(
            RoundedRectangle(cornerRadius: DesignTokens.Radius.md, style: .continuous)
                .strokeBorder(.white.opacity(0.14), lineWidth: 1)
        )
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
                .foregroundStyle(DesignTokens.Palette.surface)
                .frame(maxWidth: 280)
        }
        .padding(DesignTokens.Space.md)
        .background {
            RoundedRectangle(cornerRadius: DesignTokens.Radius.lg, style: .continuous)
                .fill(.ultraThinMaterial)
                .overlay(
                    RoundedRectangle(cornerRadius: DesignTokens.Radius.lg, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [
                                    DesignTokens.Palette.deep.opacity(0.52),
                                    DesignTokens.Palette.deepInk.opacity(0.4)
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                )
                .overlay(
                    RoundedRectangle(cornerRadius: DesignTokens.Radius.lg, style: .continuous)
                        .strokeBorder(.white.opacity(0.12), lineWidth: 1)
                )
        }
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
    }

    private var recordingTitle: String {
        if model.readiness.backgroundCollection == .upgradeRequired { return "Needs Always Location" }
        return model.isPassiveMonitoringEnabled ? "Recording" : "Paused"
    }

    private var headerSubtitle: String {
        if !isMapLoaded && mapLoadError == nil { return "Loading community layer…" }
        if model.readiness.backgroundCollection == .upgradeRequired { return "Allow Always Location so RoadSense can keep collecting after you leave the app." }
        if model.readiness.showsPrivacyRiskWarning { return "Privacy zones are optional extra protection." }
        if model.pendingUploadCount > 0 { return "\(model.pendingUploadCount) uploads waiting" }
        if model.userStatsSummary.acceptedReadingCount == 0 { return "No drives yet" }
        return mappedValue + " mapped"
    }

    private var recordingTint: Color {
        if model.readiness.backgroundCollection == .upgradeRequired { return DesignTokens.Palette.warning }
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
        if model.readiness.backgroundCollection == .upgradeRequired { return "Allow in background" }
        if model.isCollectionPausedByUser { return "Turn collection back on" }
        return "View stats"
    }

    private func handlePrimaryAction() {
        if model.readiness.backgroundCollection == .upgradeRequired {
            model.requestAlwaysLocationUpgrade()
        } else if model.isCollectionPausedByUser {
            model.startPassiveMonitoring()
        } else {
            onShowStats()
        }
    }

    private func handleMarkPotholeTap() {
        let feedback: PotholeFeedback
        switch model.markPothole() {
        case let .queued(actionID):
            feedback = PotholeFeedback(
                actionID: actionID,
                title: "Pothole marked",
                message: "It will send automatically after 5 seconds unless you undo it.",
                iconName: "checkmark.circle.fill",
                tint: DesignTokens.Palette.signalSoft,
                dismissDelay: .seconds(5.2)
            )
        case .unavailableLocation:
            feedback = PotholeFeedback(
                title: "Need a fresh GPS fix",
                message: "Keep the app open for a moment, then try again.",
                iconName: "location.slash.fill",
                tint: DesignTokens.Palette.warning,
                dismissDelay: .seconds(3)
            )
        case .insidePrivacyZone:
            feedback = PotholeFeedback(
                title: "Inside a privacy zone",
                message: "RoadSense will not report potholes from an excluded area.",
                iconName: "hand.raised.fill",
                tint: DesignTokens.Palette.warning,
                dismissDelay: .seconds(3)
            )
        }

        withAnimation(DesignTokens.Motion.enter) {
            potholeFeedback = feedback
        }
    }

    private func handleTakePhotoTap(segmentID: UUID? = nil) {
        guard let context = model.potholePhotoCaptureContext() else {
            withAnimation(DesignTokens.Motion.enter) {
                potholeFeedback = PotholeFeedback(
                    title: "Pull over first",
                    message: "Photo reports only work below 5 km/h with a fresh GPS fix.",
                    iconName: "camera.metering.unknown",
                    tint: DesignTokens.Palette.warning,
                    dismissDelay: .seconds(3)
                )
            }
            return
        }

        scopedPhotoSegmentID = segmentID
        photoCaptureContext = context
        isShowingCamera = true
    }

    private func handlePhotoSubmit(_ data: Data) {
        let feedback: PotholeFeedback
        switch model.submitPotholePhoto(rawImageData: data, segmentID: scopedPhotoSegmentID) {
        case .queued:
            feedback = PotholeFeedback(
                title: "Photo queued",
                message: "Thanks. RoadSense will upload it and send it to moderation automatically.",
                iconName: "checkmark.circle.fill",
                tint: DesignTokens.Palette.signalSoft,
                dismissDelay: .seconds(3.5)
            )
        case .safetyRestricted:
            feedback = PotholeFeedback(
                title: "Pull over first",
                message: "Photo reports only work below 5 km/h with a fresh GPS fix.",
                iconName: "camera.metering.unknown",
                tint: DesignTokens.Palette.warning,
                dismissDelay: .seconds(3)
            )
        case .unavailableLocation:
            feedback = PotholeFeedback(
                title: "Need a fresh GPS fix",
                message: "Keep the app open for a moment, then try again.",
                iconName: "location.slash.fill",
                tint: DesignTokens.Palette.warning,
                dismissDelay: .seconds(3)
            )
        case .insidePrivacyZone:
            feedback = PotholeFeedback(
                title: "Inside a privacy zone",
                message: "RoadSense will not send photo reports from an excluded area.",
                iconName: "hand.raised.fill",
                tint: DesignTokens.Palette.warning,
                dismissDelay: .seconds(3)
            )
        }

        scopedPhotoSegmentID = nil
        photoCaptureContext = nil

        withAnimation(DesignTokens.Motion.enter) {
            potholeFeedback = feedback
        }
    }

    private func submitPromptFollowUp(_ actionType: PotholeActionType, prompt: FollowUpPrompt) {
        let result = model.queuePotholeFollowUp(
            potholeReportID: prompt.pothole.id,
            actionType: actionType
        )
        withAnimation(DesignTokens.Motion.standard) {
            followUpPrompt = nil
        }

        let feedback: PotholeFeedback
        switch result {
        case .queued:
            feedback = PotholeFeedback(
                title: "Thanks for the update",
                message: actionType == .confirmFixed
                    ? "Your “looks fixed” report will upload automatically in the background."
                    : "Your confirmation will upload automatically in the background.",
                iconName: "checkmark.circle.fill",
                tint: DesignTokens.Palette.signalSoft,
                dismissDelay: .seconds(3)
            )
        case .unavailableLocation:
            feedback = PotholeFeedback(
                title: "Need a fresh GPS fix",
                message: "Keep the app open for a moment, then try again near the pothole.",
                iconName: "location.slash.fill",
                tint: DesignTokens.Palette.warning,
                dismissDelay: .seconds(3)
            )
        case .insidePrivacyZone:
            feedback = PotholeFeedback(
                title: "Inside a privacy zone",
                message: "RoadSense will not send pothole updates from an excluded area.",
                iconName: "hand.raised.fill",
                tint: DesignTokens.Palette.warning,
                dismissDelay: .seconds(3)
            )
        }

        withAnimation(DesignTokens.Motion.enter) {
            potholeFeedback = feedback
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
            if let promptPothole = model.followUpPromptCandidate(for: detail.potholes) {
                withAnimation(DesignTokens.Motion.enter) {
                    followUpPrompt = FollowUpPrompt(pothole: promptPothole)
                }
            }
        } catch {
            selectedSegment = nil
            segmentLoadError = error.localizedDescription
        }

        isLoadingSegment = false
    }
}

private struct PotholeFeedback: Identifiable {
    let id = UUID()
    let actionID: UUID?
    let title: String
    let message: String
    let iconName: String
    let tint: Color
    let dismissDelay: Duration

    init(
        actionID: UUID? = nil,
        title: String,
        message: String,
        iconName: String,
        tint: Color,
        dismissDelay: Duration
    ) {
        self.actionID = actionID
        self.title = title
        self.message = message
        self.iconName = iconName
        self.tint = tint
        self.dismissDelay = dismissDelay
    }
}

private struct FollowUpPrompt: Identifiable {
    let id = UUID()
    let pothole: SegmentPothole
    let dismissDelay: Duration = .seconds(12)
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
