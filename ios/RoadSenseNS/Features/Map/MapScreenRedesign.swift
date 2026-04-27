import SwiftUI

/// Redesigned driving screen — production version.
///
/// 3-FAB row (Photo | Pothole | Stats), heartbeat AmbientRing, UndoChip pattern,
/// NeedsAttentionPill, IdleStatWell pro-social readout. Wires to live `AppModel`
/// state and reuses `RoadQualityMapView`, `SegmentDetailSheet`, and
/// `PotholeCameraFlowView` from the existing app.
///
/// Mounted from `ContentView` when `FeatureFlags.drivingRedesignEnabled == true`.
/// Otherwise the legacy `MapScreen` is mounted (rollback path per ADR 0001).
///
/// References:
/// - `docs/reviews/2026-04-24-design-audit.md` §7.D1 + §13
/// - `docs/adr/0001-driving-redesign-rollback.md`
struct MapScreenRedesign: View {
    @Bindable var model: AppModel
    @Binding var pendingMapTarget: DriveBoundingBox?

    let onShowStats: () -> Void
    let onShowSettings: () -> Void
    let onShowPrivacyZones: () -> Void

    // Map + segment state — parallel to MapScreen.
    @State private var selectedSegment: SegmentDetailResponse?
    @State private var isLoadingSegment = false
    @State private var segmentLoadError: String?
    @State private var isMapLoaded = false
    @State private var mapLoadError: String?

    // Camera state — parallel to MapScreen.
    @State private var photoCaptureContext: PotholePhotoCaptureContext?
    @State private var isShowingCamera = false
    @State private var isWaitingToPresentCamera = false
    @State private var scopedPhotoSegmentID: UUID?

    // Redesign-specific state.
    @State private var undoActionID: UUID?
    @State private var undoChipID = UUID()
    @State private var rejectionFeedback: RedesignRejectionFeedback?
    @State private var followUpPrompt: RedesignFollowUpPrompt?
    @State private var deferredRedesignFollowUpPrompt: RedesignFollowUpPrompt?

    /// Whether the idle "Your contribution" well is shown full-size or
    /// collapsed to a chip. Persisted so the user's choice survives launches —
    /// once they hide the well to explore the map, we don't keep reopening it.
    @AppStorage("driving.idleWellExpanded") private var idleWellExpanded: Bool = true

    var body: some View {
        ZStack(alignment: .top) {
            RoadQualityMapView(
                config: model.config,
                localDriveOverlayPoints: model.localDriveOverlayPoints,
                pendingPotholeCoordinates: model.pendingPotholeCoordinates,
                pendingMapTarget: $pendingMapTarget,
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

            // Tap-to-dismiss layer — when the idle well is expanded, a tap
            // anywhere on the map area collapses it to a chip so the user can
            // interact with the map. Map drag/zoom gestures pass through (we
            // only consume tap), and FABs / topBar / pills sit above this in
            // the ZStack and consume their own taps first.
            if showsIdleStatWell && idleWellExpanded {
                Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture {
                        withAnimation(DesignTokens.Motion.standard) {
                            idleWellExpanded = false
                        }
                    }
                    .ignoresSafeArea()
                    .accessibilityHidden(true)
            }

            // Bottom gradient scrim — keeps the FAB cluster + labels legible
            // over bright Mapbox tiles. Fades to fully transparent ~40% up
            // so it never feels like a heavy overlay.
            VStack {
                Spacer()
                LinearGradient(
                    colors: [
                        Color.black.opacity(0),
                        Color.black.opacity(0.45)
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .frame(height: 280)
                .allowsHitTesting(false)
            }
            .ignoresSafeArea()

            VStack(spacing: 0) {
                topBar
                    .padding(.horizontal, DesignTokens.Space.md)
                    .padding(.top, DesignTokens.Space.sm)

                if let attention = attentionState {
                    NeedsAttentionPill(state: attention) {
                        handleAttentionTap(attention)
                    }
                    .padding(.horizontal, DesignTokens.Space.md)
                    .padding(.top, DesignTokens.Space.xs)
                    .transition(.move(edge: .top).combined(with: .opacity))
                }

                collapsedContributionChip
                    .padding(.top, DesignTokens.Space.sm)

                Spacer(minLength: 0)

                centerStageContent

                Spacer(minLength: 0)

                bottomFabCluster
                    .padding(.horizontal, DesignTokens.Space.xl)
                    .padding(.bottom, DesignTokens.Space.xl)
            }

            if isLoadingSegment {
                loadingVeil
            }
        }
        .animation(DesignTokens.Motion.standard, value: attentionState)
        .sheet(item: $selectedSegment, onDismiss: handleSegmentDismiss) { segment in
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
        .fullScreenCover(isPresented: $isShowingCamera, onDismiss: handleCameraDismiss) {
            if let photoCaptureContext {
                PotholeCameraFlowView(
                    coordinateLabel: photoCaptureContext.coordinateLabel,
                    isLikelyMoving: (model.currentSpeedKmh ?? 0) > 25.0,
                    onCancel: {
                        isShowingCamera = false
                    },
                    onSubmit: { data in
                        let segmentID = scopedPhotoSegmentID
                        let locationSample = photoCaptureContext.locationSample
                        isShowingCamera = false
                        Task {
                            await handlePhotoSubmit(data, segmentID: segmentID, locationSample: locationSample)
                        }
                    }
                )
            } else {
                PotholeCameraUnavailableView {
                    isShowingCamera = false
                }
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

                if let rejectionFeedback {
                    rejectionBanner(rejectionFeedback)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                        .task(id: rejectionFeedback.id) {
                            try? await Task.sleep(for: rejectionFeedback.dismissDelay)
                            guard self.rejectionFeedback?.id == rejectionFeedback.id else { return }
                            withAnimation(DesignTokens.Motion.standard) {
                                self.rejectionFeedback = nil
                            }
                        }
                }
            }
            .padding(.horizontal, DesignTokens.Space.md)
            .padding(.bottom, 240) // sits above the FAB cluster
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
            BrandChip(
                isRecording: model.isActivelyCollecting,
                accessibilityIdentifier: "map.title"
            )
            .accessibilitySortPriority(2)

            Spacer(minLength: DesignTokens.Space.sm)

            ChromeButton(
                systemName: "gearshape.fill",
                accessibilityLabel: "Settings",
                accessibilityIdentifier: "map.settings-button",
                action: onShowSettings
            )
            .accessibilitySortPriority(1)
        }
    }

    // MARK: - Center stage

    @ViewBuilder
    private var centerStageContent: some View {
        if showsFirstRunIllustration {
            FirstRunIllustration()
                .padding(DesignTokens.Space.lg)
                .background(centerScrimBackground)
                .transition(.opacity)
                .accessibilitySortPriority(3)
        } else if showsIdleStatWell, idleWellExpanded {
            IdleStatWell(
                kmThisMonth: model.userStatsSummary.totalKmRecorded,
                communityKmThisWeek: 0, // §11 stats_public view will populate this
                communityDriversThisWeek: 0,
                onDismiss: {
                    withAnimation(DesignTokens.Motion.standard) {
                        idleWellExpanded = false
                    }
                }
            )
            .padding(DesignTokens.Space.lg)
            .background(centerScrimBackground)
            .transition(.scale(scale: 0.92).combined(with: .opacity))
            .accessibilitySortPriority(3)
        }
    }

    /// Compact pill rendered near the top of the screen when the user has
    /// dismissed `IdleStatWell` so the contribution signal is never gone — just
    /// out of the way.
    @ViewBuilder
    private var collapsedContributionChip: some View {
        if showsIdleStatWell, !idleWellExpanded {
            ContributionChip(
                kmThisMonth: model.userStatsSummary.totalKmRecorded,
                onExpand: {
                    withAnimation(DesignTokens.Motion.standard) {
                        idleWellExpanded = true
                    }
                }
            )
            .transition(.move(edge: .top).combined(with: .opacity))
            .accessibilitySortPriority(3)
        }
    }

    /// Soft pill-shaped backdrop behind center-stage content so the white type
    /// stays legible over bright Mapbox tiles. Kept narrow + low-opacity so the
    /// map underneath remains readable — the well is a subtle headline, not a
    /// modal layer.
    private var centerScrimBackground: some View {
        RoundedRectangle(cornerRadius: DesignTokens.Radius.lg, style: .continuous)
            .fill(.ultraThinMaterial)
            .overlay(
                RoundedRectangle(cornerRadius: DesignTokens.Radius.lg, style: .continuous)
                    .fill(DesignTokens.Palette.deep.opacity(0.42))
            )
            .overlay(
                RoundedRectangle(cornerRadius: DesignTokens.Radius.lg, style: .continuous)
                    .strokeBorder(.white.opacity(0.10), lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.14), radius: 14, y: 6)
    }

    // MARK: - Bottom FAB cluster

    private var bottomFabCluster: some View {
        VStack(spacing: DesignTokens.Space.md) {
            if undoActionID != nil {
                UndoChip(action: handleUndoTap)
                    .id(undoChipID)
                    .transition(.scale.combined(with: .opacity))
                    .task(id: undoChipID) {
                        try? await Task.sleep(for: .seconds(5))
                        guard !Task.isCancelled else { return }
                        await dismissUndoChipIfStale()
                    }
                    .accessibilitySortPriority(8)
            }

            HStack(alignment: .bottom, spacing: 0) {
                Spacer()
                SecondaryFAB(
                    systemName: "camera.viewfinder",
                    label: BrandVoice.Driving.photoLabel,
                    accessibilityLabel: BrandVoice.Driving.photoAccessibilityLabel,
                    accessibilityHint: BrandVoice.Driving.photoAccessibilityHint,
                    accessibilityIdentifier: "map.take-photo-button",
                    action: { handleTakePhotoTap() }
                )
                .accessibilitySortPriority(6)

                Spacer()

                HeroPotholeFAB(
                    isRecording: model.isActivelyCollecting,
                    accessibilityIdentifier: "map.mark-pothole-button",
                    action: handleMarkPotholeTap
                )
                .accessibilitySortPriority(10) // highest — first via VoiceOver

                Spacer()

                SecondaryFAB(
                    systemName: "chart.bar.fill",
                    label: BrandVoice.Driving.statsLabel,
                    accessibilityLabel: BrandVoice.Driving.statsAccessibilityLabel,
                    accessibilityIdentifier: "map.stats-button",
                    action: onShowStats
                )
                .accessibilitySortPriority(5)

                Spacer()
            }
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

    // MARK: - Banners

    private func rejectionBanner(_ feedback: RedesignRejectionFeedback) -> some View {
        HStack(alignment: .center, spacing: DesignTokens.Space.md) {
            ZStack {
                Circle()
                    .fill(feedback.tint.opacity(0.22))
                Circle()
                    .strokeBorder(feedback.tint.opacity(0.5), lineWidth: 1)
                Image(systemName: feedback.iconName)
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(feedback.tint)
            }
            .frame(width: 32, height: 32)

            VStack(alignment: .leading, spacing: 2) {
                Text(feedback.title)
                    .font(.system(size: 14, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                Text(feedback.message)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white.opacity(0.78))
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: DesignTokens.Space.xs)
        }
        .padding(.horizontal, DesignTokens.Space.md)
        .padding(.vertical, DesignTokens.Space.sm)
        .background(
            RoundedRectangle(cornerRadius: DesignTokens.Radius.lg, style: .continuous)
                .fill(.ultraThinMaterial)
                .overlay(
                    RoundedRectangle(cornerRadius: DesignTokens.Radius.lg, style: .continuous)
                        .fill(DesignTokens.Palette.deep.opacity(0.78))
                )
        )
        .overlay(
            RoundedRectangle(cornerRadius: DesignTokens.Radius.lg, style: .continuous)
                .strokeBorder(.white.opacity(0.12), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.22), radius: 14, y: 6)
    }

    private func followUpPromptBanner(_ prompt: RedesignFollowUpPrompt) -> some View {
        VStack(alignment: .leading, spacing: DesignTokens.Space.sm) {
            HStack(spacing: DesignTokens.Space.sm) {
                Image(systemName: "questionmark.circle.fill")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(DesignTokens.Palette.warning)

                VStack(alignment: .leading, spacing: 2) {
                    Text("Still there?")
                        .font(.system(.headline, design: .rounded, weight: .bold))
                        .foregroundStyle(.white)
                    Text("You're stopped near an active pothole marker. Want to confirm it or say it looks fixed?")
                        .font(.subheadline)
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

    // MARK: - Derived state

    private var showsFirstRunIllustration: Bool {
        isMapLoaded
            && mapLoadError == nil
            && model.userStatsSummary.acceptedReadingCount == 0
            && model.localDriveOverlayPoints.isEmpty
            && !model.isActivelyCollecting
    }

    private var showsIdleStatWell: Bool {
        isMapLoaded
            && mapLoadError == nil
            && !model.isActivelyCollecting
            && model.userStatsSummary.totalKmRecorded >= 0.05
    }

    /// Highest-priority attention state per §13.5. Returns `nil` when nothing
    /// needs the user's attention.
    private var attentionState: AttentionState? {
        if model.readiness.backgroundCollection == .upgradeRequired {
            return .alwaysLocationUpgrade
        }
        if model.snapshot.location == .denied {
            return .locationDenied
        }
        if model.snapshot.motion == .denied {
            return .motionDenied
        }
        if mapLoadError != nil {
            return .mapLoadFailed()
        }
        if model.isCollectionPausedByUser {
            return .paused
        }
        if model.uploadStatusSummary.failedPermanentBatchCount > 0
            || model.potholePhotoStatusSummary.failedPermanentCount > 0 {
            return .failedUploads
        }
        return nil
    }

    // MARK: - Actions

    private func handleAttentionTap(_ state: AttentionState) {
        switch state {
        case .alwaysLocationUpgrade:
            model.requestAlwaysLocationUpgrade()
        case .locationDenied, .motionDenied:
            if let url = URL(string: UIApplication.openSettingsURLString) {
                UIApplication.shared.open(url)
            }
        case .mapLoadFailed:
            mapLoadError = nil // re-trigger map load
        case .paused:
            model.startPassiveMonitoring()
        case .failedUploads:
            onShowSettings()
        case .thermalPaused, .offline:
            // Informational only — no action.
            break
        }
    }

    private func handleMarkPotholeTap() {
        switch model.markPothole() {
        case let .queued(actionID):
            withAnimation(DesignTokens.Motion.standard) {
                undoActionID = actionID
                undoChipID = UUID()
            }
        case .unavailableLocation:
            withAnimation(DesignTokens.Motion.enter) {
                rejectionFeedback = RedesignRejectionFeedback(
                    title: BrandVoice.Failures.needFreshGPSTitle,
                    message: BrandVoice.Failures.needFreshGPSBody,
                    iconName: "location.slash.fill",
                    tint: DesignTokens.Palette.warning,
                    dismissDelay: .seconds(3)
                )
            }
        case .insidePrivacyZone:
            withAnimation(DesignTokens.Motion.enter) {
                rejectionFeedback = RedesignRejectionFeedback(
                    title: BrandVoice.Failures.insidePrivacyZoneTitle,
                    message: BrandVoice.Failures.insidePrivacyZoneBody,
                    iconName: "hand.raised.fill",
                    tint: DesignTokens.Palette.warning,
                    dismissDelay: .seconds(3)
                )
            }
        }
    }

    private func handleUndoTap() {
        guard let actionID = undoActionID else { return }
        model.undoPotholeReport(id: actionID)
        withAnimation(DesignTokens.Motion.standard) {
            undoActionID = nil
        }
    }

    @MainActor
    private func dismissUndoChipIfStale() async {
        withAnimation(DesignTokens.Motion.standard) {
            undoActionID = nil
        }
    }

    private func handleTakePhotoTap(segmentID: UUID? = nil) {
        guard let context = model.potholePhotoCaptureContext() else {
            withAnimation(DesignTokens.Motion.enter) {
                rejectionFeedback = RedesignRejectionFeedback(
                    title: BrandVoice.Failures.needFreshGPSTitle,
                    message: BrandVoice.Failures.needFreshGPSBody,
                    iconName: "camera.metering.unknown",
                    tint: DesignTokens.Palette.warning,
                    dismissDelay: .seconds(3)
                )
            }
            return
        }

        scopedPhotoSegmentID = segmentID
        photoCaptureContext = context
        if segmentID != nil {
            deferredRedesignFollowUpPrompt = nil
        }

        guard selectedSegment != nil else {
            isShowingCamera = true
            return
        }

        isWaitingToPresentCamera = true
        selectedSegment = nil
    }

    private func handlePhotoSubmit(_ data: Data, segmentID: UUID?, locationSample: LocationSample?) async {
        let feedback: RedesignRejectionFeedback?
        switch await model.submitPotholePhoto(
            rawImageData: data,
            segmentID: segmentID,
            locationSample: locationSample
        ) {
        case .queued:
            feedback = RedesignRejectionFeedback(
                title: BrandVoice.Failures.photoQueuedTitle,
                message: BrandVoice.Failures.photoQueuedBody,
                iconName: "checkmark.circle.fill",
                tint: DesignTokens.Palette.signalSoft,
                dismissDelay: .seconds(3.5)
            )
        case .unavailableLocation:
            feedback = RedesignRejectionFeedback(
                title: BrandVoice.Failures.needFreshGPSTitle,
                message: BrandVoice.Failures.needFreshGPSBody,
                iconName: "location.slash.fill",
                tint: DesignTokens.Palette.warning,
                dismissDelay: .seconds(3)
            )
        case .insidePrivacyZone:
            feedback = RedesignRejectionFeedback(
                title: BrandVoice.Failures.insidePrivacyZoneTitle,
                message: BrandVoice.Failures.insidePrivacyZoneBody,
                iconName: "hand.raised.fill",
                tint: DesignTokens.Palette.warning,
                dismissDelay: .seconds(3)
            )
        case .outsideCoverage:
            feedback = RedesignRejectionFeedback(
                title: BrandVoice.Failures.outsideCoverageTitle,
                message: BrandVoice.Failures.outsideCoverageBody,
                iconName: "map.circle.fill",
                tint: DesignTokens.Palette.warning,
                dismissDelay: .seconds(3)
            )
        }

        scopedPhotoSegmentID = nil
        photoCaptureContext = nil

        if let feedback {
            withAnimation(DesignTokens.Motion.enter) {
                rejectionFeedback = feedback
            }
        }
    }

    private func submitPromptFollowUp(_ actionType: PotholeActionType, prompt: RedesignFollowUpPrompt) {
        _ = model.queuePotholeFollowUp(
            potholeReportID: prompt.pothole.id,
            actionType: actionType
        )
        withAnimation(DesignTokens.Motion.standard) {
            followUpPrompt = nil
        }
    }

    private func loadSegment(id: UUID) async {
        guard !isLoadingSegment else { return }

        isLoadingSegment = true
        segmentLoadError = nil
        followUpPrompt = nil
        deferredRedesignFollowUpPrompt = nil

        do {
            try await Task.sleep(for: .milliseconds(140))
            let detail = try await model.fetchSegmentDetail(id: id)
            selectedSegment = detail
            if let promptPothole = model.followUpPromptCandidate(for: detail.potholes) {
                deferredRedesignFollowUpPrompt = RedesignFollowUpPrompt(pothole: promptPothole)
            }
        } catch {
            selectedSegment = nil
            segmentLoadError = error.localizedDescription
        }

        isLoadingSegment = false
    }

    private func handleSegmentDismiss() {
        if isWaitingToPresentCamera {
            isWaitingToPresentCamera = false
            isShowingCamera = true
            return
        }

        showDeferredRedesignFollowUpPromptIfNeeded()
    }

    private func handleCameraDismiss() {
        photoCaptureContext = nil
        scopedPhotoSegmentID = nil
    }

    private func showDeferredRedesignFollowUpPromptIfNeeded() {
        guard selectedSegment == nil,
              !isShowingCamera,
              let prompt = deferredRedesignFollowUpPrompt else {
            return
        }

        deferredRedesignFollowUpPrompt = nil
        withAnimation(DesignTokens.Motion.enter) {
            followUpPrompt = prompt
        }
    }
}

// MARK: - Helper types

struct RedesignRejectionFeedback: Identifiable, Equatable {
    let id = UUID()
    let title: String
    let message: String
    let iconName: String
    let tint: Color
    let dismissDelay: Duration

    static func == (lhs: RedesignRejectionFeedback, rhs: RedesignRejectionFeedback) -> Bool {
        lhs.id == rhs.id
    }
}

struct RedesignFollowUpPrompt: Identifiable, Equatable {
    let id = UUID()
    let pothole: SegmentPothole
    let dismissDelay: Duration = .seconds(12)

    static func == (lhs: RedesignFollowUpPrompt, rhs: RedesignFollowUpPrompt) -> Bool {
        lhs.id == rhs.id
    }
}
