import SwiftUI
import UIKit

/// Explainer sheet shown before the iOS Settings deep-link when the user has
/// only granted "When In Use" location. Backlog item B068 in
/// `docs/implementation/08-implementation-backlog.md` — non-technical testers
/// were dropped into Settings cold and didn't know which toggle to flip.
///
/// The sheet narrates *why* Always is required and the two taps inside Settings.
/// Tapping the primary button calls `onOpenSettings`, which the host wires to
/// `AppModel.requestAlwaysLocationUpgrade()` (which itself first re-requests
/// Always inline, then falls back to a Settings deep-link).
struct AlwaysLocationUpgradeSheet: View {
    let onOpenSettings: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DesignTokens.Space.lg) {
                heroIcon

                VStack(alignment: .leading, spacing: DesignTokens.Space.sm) {
                    Text(BrandVoice.AlwaysUpgrade.title)
                        .font(.system(size: 22, weight: .bold, design: .rounded))
                        .foregroundStyle(DesignTokens.Palette.ink)
                        .fixedSize(horizontal: false, vertical: true)

                    Text(BrandVoice.AlwaysUpgrade.mission)
                        .font(.system(size: 15))
                        .foregroundStyle(DesignTokens.Palette.inkMuted)
                        .fixedSize(horizontal: false, vertical: true)
                }

                whySection
                stepsSection

                Text(BrandVoice.AlwaysUpgrade.returnHint)
                    .font(.system(size: 13))
                    .foregroundStyle(DesignTokens.Palette.inkMuted)
                    .fixedSize(horizontal: false, vertical: true)

                actions
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, DesignTokens.Space.xl)
            .padding(.top, DesignTokens.Space.xl)
            .padding(.bottom, DesignTokens.Space.xxl)
        }
        .background(backgroundGradient.ignoresSafeArea())
        .accessibilityIdentifier("alwaysUpgrade.sheet")
    }

    private var backgroundGradient: some View {
        LinearGradient(
            colors: [DesignTokens.Palette.canvas, DesignTokens.Palette.canvasSunken],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    private var heroIcon: some View {
        ZStack {
            Circle()
                .fill(DesignTokens.Palette.deep.opacity(0.12))
                .frame(width: 56, height: 56)
            Image(systemName: "location.north.circle.fill")
                .font(.system(size: 26, weight: .semibold))
                .foregroundStyle(DesignTokens.Palette.deep)
        }
    }

    private var whySection: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Space.xs) {
            Text(BrandVoice.AlwaysUpgrade.whyTitle)
                .font(.system(size: 13, weight: .bold))
                .tracking(0.8)
                .foregroundStyle(DesignTokens.Palette.inkMuted)
                .textCase(.uppercase)

            Text(.init(BrandVoice.AlwaysUpgrade.whyBody))
                .font(.system(size: 15))
                .foregroundStyle(DesignTokens.Palette.ink)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(DesignTokens.Space.lg)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: DesignTokens.Radius.md, style: .continuous)
                .fill(DesignTokens.Palette.surface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: DesignTokens.Radius.md, style: .continuous)
                .strokeBorder(DesignTokens.Palette.border, lineWidth: 1)
        )
    }

    private var stepsSection: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Space.sm) {
            Text(BrandVoice.AlwaysUpgrade.stepsTitle)
                .font(.system(size: 13, weight: .bold))
                .tracking(0.8)
                .foregroundStyle(DesignTokens.Palette.inkMuted)
                .textCase(.uppercase)

            stepRow(number: 1, markdown: BrandVoice.AlwaysUpgrade.stepOne)
            stepRow(number: 2, markdown: BrandVoice.AlwaysUpgrade.stepTwo)
        }
    }

    private func stepRow(number: Int, markdown: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: DesignTokens.Space.md) {
            ZStack {
                Circle()
                    .fill(DesignTokens.Palette.deep)
                    .frame(width: 26, height: 26)
                Text("\(number)")
                    .font(.system(size: 13, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
            }

            Text(.init(markdown))
                .font(.system(size: 15))
                .foregroundStyle(DesignTokens.Palette.ink)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, DesignTokens.Space.md)
        .padding(.vertical, DesignTokens.Space.sm)
        .background(
            RoundedRectangle(cornerRadius: DesignTokens.Radius.sm, style: .continuous)
                .fill(DesignTokens.Palette.canvasSunken)
        )
    }

    private var actions: some View {
        VStack(spacing: DesignTokens.Space.sm) {
            Button {
                onOpenSettings()
            } label: {
                Text(BrandVoice.AlwaysUpgrade.primaryButton)
                    .font(.system(size: 16, weight: .semibold))
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(DesignTokens.Palette.deep)
            .controlSize(.large)
            .accessibilityHint(BrandVoice.AlwaysUpgrade.accessibilityHint)
            .accessibilityIdentifier("alwaysUpgrade.openSettings")

            Button(BrandVoice.AlwaysUpgrade.secondaryButton) {
                onDismiss()
            }
            .buttonStyle(.bordered)
            .tint(DesignTokens.Palette.inkMuted)
            .controlSize(.large)
            .frame(maxWidth: .infinity)
            .accessibilityIdentifier("alwaysUpgrade.dismiss")
        }
    }
}

#Preview {
    AlwaysLocationUpgradeSheet(
        onOpenSettings: {},
        onDismiss: {}
    )
}
