import SwiftUI

struct OnboardingFlowView: View {
    @Bindable var model: AppModel

    var body: some View {
        ZStack {
            backgroundGradient
                .ignoresSafeArea()

            ScrollView {
                VStack(alignment: .leading, spacing: DesignTokens.Space.xl) {
                    header
                    missionHook
                    stageContent
                    progressTrail
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, DesignTokens.Space.xl)
                .padding(.top, DesignTokens.Space.xxl)
                .padding(.bottom, DesignTokens.Space.xxxl)
            }
        }
    }

    private var backgroundGradient: some View {
        LinearGradient(
            colors: [
                DesignTokens.Palette.canvas,
                DesignTokens.Palette.canvasSunken,
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Space.xs) {
            HStack(spacing: DesignTokens.Space.sm) {
                brandMark
                Text("RoadSense NS")
                    .font(.system(size: 17, weight: .bold, design: .rounded))
                    .foregroundStyle(DesignTokens.Palette.deep)
            }

            Text(eyebrow)
                .font(.system(size: 11, weight: .bold))
                .tracking(1.2)
                .foregroundStyle(DesignTokens.Palette.inkMuted)
                .textCase(.uppercase)
        }
    }

    private var brandMark: some View {
        BrandMark(size: 28)
    }

    /// One-line mission hook from §7.O4. Sets the civic-pride frame
    /// before the first stage card.
    private var missionHook: some View {
        Text(BrandVoice.Onboarding.missionHook)
            .font(.system(size: 15, weight: .medium))
            .foregroundStyle(DesignTokens.Palette.inkMuted)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityIdentifier("onboarding.mission-hook")
    }

    private var eyebrow: String {
        switch model.readiness.stage {
        case .permissionsRequired: return BrandVoice.Onboarding.stepEyebrowPermissions
        case .permissionHelp:      return BrandVoice.Onboarding.stepEyebrowPermissions
        case .ready:               return BrandVoice.Onboarding.stepEyebrowReady
        }
    }

    @ViewBuilder
    private var stageContent: some View {
        switch model.readiness.stage {
        case .permissionsRequired: permissionIntro
        case .permissionHelp:      permissionHelp
        case .ready:               readyState
        }
    }

    private var progressTrail: some View {
        HStack(spacing: DesignTokens.Space.xs) {
            progressDot(isActive: true, isComplete: stageIndex > 0)
            progressBar(isComplete: stageIndex > 0)
            progressDot(isActive: stageIndex >= 1, isComplete: stageIndex > 1)
            progressBar(isComplete: stageIndex > 1)
            progressDot(isActive: stageIndex >= 2, isComplete: stageIndex > 2)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, DesignTokens.Space.md)
    }

    private func progressDot(isActive: Bool, isComplete: Bool) -> some View {
        Circle()
            .fill(isComplete ? DesignTokens.Palette.smooth : (isActive ? DesignTokens.Palette.deep : DesignTokens.Palette.border))
            .frame(width: 10, height: 10)
    }

    private func progressBar(isComplete: Bool) -> some View {
        Capsule()
            .fill(isComplete ? DesignTokens.Palette.smooth.opacity(0.5) : DesignTokens.Palette.border)
            .frame(height: 2)
    }

    private var stageIndex: Int {
        switch model.readiness.stage {
        case .permissionsRequired, .permissionHelp: return 0
        case .ready:                                return 1
        }
    }

    // MARK: - Stages

    private var permissionIntro: some View {
        stageCard(
            iconSystemName: "location.north.circle.fill",
            iconTint: DesignTokens.Palette.deep,
            title: "We need two permissions before your first drive.",
            body: "Location while using the app, then Motion & Fitness. Always Location comes later, once you’ve seen a drive succeed."
        ) {
            VStack(alignment: .leading, spacing: DesignTokens.Space.md) {
                permissionTip(
                    icon: "location.fill",
                    title: BrandVoice.Onboarding.locationPermissionTitle,
                    guidance: BrandVoice.Onboarding.locationPermissionGuidance
                )
                permissionTip(
                    icon: "figure.walk.motion",
                    title: BrandVoice.Onboarding.motionPermissionTitle,
                    guidance: BrandVoice.Onboarding.motionPermissionGuidance
                )

                Button {
                    Task { await model.requestInitialPermissions() }
                } label: {
                    if model.isRequestingPermissions {
                        ProgressView()
                            .tint(.white)
                            .frame(maxWidth: .infinity)
                    } else {
                        Text(BrandVoice.Onboarding.continueButton)
                            .font(.system(size: 16, weight: .semibold))
                            .frame(maxWidth: .infinity)
                    }
                }
                .buttonStyle(.borderedProminent)
                .tint(DesignTokens.Palette.deep)
                .controlSize(.large)
                .disabled(model.isRequestingPermissions)
                .accessibilityIdentifier("onboarding.continue")
            }
        }
    }

    private func permissionTip(icon: String, title: String, guidance: String) -> some View {
        HStack(alignment: .top, spacing: DesignTokens.Space.sm) {
            Image(systemName: icon)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(DesignTokens.Palette.deep)
                .frame(width: 20, alignment: .center)
                .padding(.top, 1)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(DesignTokens.Palette.ink)
                Text(.init(guidance))
                    .font(.system(size: 13))
                    .foregroundStyle(DesignTokens.Palette.inkMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, DesignTokens.Space.md)
        .padding(.vertical, DesignTokens.Space.sm)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DesignTokens.Palette.canvasSunken, in: RoundedRectangle(cornerRadius: DesignTokens.Radius.sm, style: .continuous))
    }

    private var permissionHelp: some View {
        stageCard(
            iconSystemName: "exclamationmark.triangle.fill",
            iconTint: DesignTokens.Palette.warning,
            title: BrandVoice.Onboarding.permissionsIncompleteTitle,
            body: BrandVoice.Onboarding.permissionsIncompleteBody
        ) {
            VStack(alignment: .leading, spacing: DesignTokens.Space.md) {
                permissionStatusSummary

                Button(BrandVoice.Onboarding.refreshStatusButton) { model.refreshPermissions() }
                    .buttonStyle(.borderedProminent)
                    .tint(DesignTokens.Palette.deep)
                    .controlSize(.large)
                    .frame(maxWidth: .infinity)
                    .accessibilityIdentifier("onboarding.refresh-status")
            }
        }
    }

    /// Ready state: §7.O3 drops the "Optional: manage privacy zones" CTA;
    /// §7.O1's Always-Location contract line lives in `readySubtitle` below.
    private var readyState: some View {
        stageCard(
            iconSystemName: "checkmark.seal.fill",
            iconTint: DesignTokens.Palette.smooth,
            title: BrandVoice.Onboarding.readyTitle,
            body: readySubtitle
        ) {
            VStack(alignment: .leading, spacing: DesignTokens.Space.md) {
                permissionStatusSummary
            }
        }
    }

    private var readySubtitle: String {
        BrandVoice.Onboarding.readySubtitleDefault
            + "\n\n"
            + BrandVoice.Onboarding.alwaysLocationContract
    }

    // MARK: - Shared building blocks

    @ViewBuilder
    private func stageCard<Content: View>(
        iconSystemName: String,
        iconTint: Color,
        title: String,
        body: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: DesignTokens.Space.md) {
            ZStack {
                Circle()
                    .fill(iconTint.opacity(0.12))
                    .frame(width: 48, height: 48)
                Image(systemName: iconSystemName)
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(iconTint)
            }

            VStack(alignment: .leading, spacing: DesignTokens.Space.xs) {
                Text(title)
                    .font(.system(size: 22, weight: .bold, design: .rounded))
                    .foregroundStyle(DesignTokens.Palette.ink)
                    .fixedSize(horizontal: false, vertical: true)

                Text(body)
                    .font(.system(size: 15))
                    .foregroundStyle(DesignTokens.Palette.inkMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }

            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(DesignTokens.Space.xl)
        .background(DesignTokens.Palette.surface, in: RoundedRectangle(cornerRadius: DesignTokens.Radius.lg, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: DesignTokens.Radius.lg, style: .continuous)
                .strokeBorder(DesignTokens.Palette.border, lineWidth: 1)
        )
        .shadow(color: Color.black.opacity(0.06), radius: 20, y: 10)
    }

    private var permissionStatusSummary: some View {
        VStack(spacing: 0) {
            statusRow(label: "Location", value: model.snapshot.location.displayName)
            Divider()
            statusRow(label: "Motion", value: model.snapshot.motion.displayName)
            Divider()
            statusRow(label: "Runs in background", value: model.readiness.backgroundCollection.displayName)
        }
        .background(DesignTokens.Palette.canvasSunken, in: RoundedRectangle(cornerRadius: DesignTokens.Radius.md, style: .continuous))
    }

    private func statusRow(label: String, value: String) -> some View {
        HStack {
            Text(label)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(DesignTokens.Palette.ink)
            Spacer()
            Text(value)
                .font(.system(size: 14))
                .foregroundStyle(DesignTokens.Palette.inkMuted)
        }
        .padding(.horizontal, DesignTokens.Space.md)
        .padding(.vertical, DesignTokens.Space.sm)
    }
}
