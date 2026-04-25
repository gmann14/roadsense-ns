import SwiftUI

/// Single-pill UI that surfaces the highest-priority `AttentionState` on the
/// driving screen. Sits between the top brand chip and the map content.
/// Reference: `docs/reviews/2026-04-24-design-audit.md` §13.5.
///
/// One state at a time. Caller is responsible for determining which state
/// (if any) to surface — see `AppModel.attentionState` once that lands in
/// Phase 3.
struct NeedsAttentionPill: View {
    let state: AttentionState
    let onTap: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pulsePhase: Double = 0

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: DesignTokens.Space.xs) {
                Image(systemName: iconName)
                    .font(.system(size: 13, weight: .bold))
                Text(state.copy)
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
            }
            .foregroundStyle(.white)
            .padding(.horizontal, DesignTokens.Space.md)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                Capsule()
                    .fill(backgroundColor)
                    .overlay(
                        Capsule()
                            .strokeBorder(.white.opacity(0.22), lineWidth: 1)
                    )
                    .shadow(color: .black.opacity(0.22), radius: 10, y: 4)
            )
            .scaleEffect(reduceMotion ? 1 : (1 + pulsePhase * 0.015))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(state.copy)
        .accessibilityHint(state.accessibilityHint)
        .accessibilityAddTraits(.isButton)
        .onAppear {
            guard !reduceMotion, state.isActionable else { return }
            withAnimation(.easeInOut(duration: 1.4).repeatForever(autoreverses: true)) {
                pulsePhase = 1
            }
        }
    }

    private var iconName: String {
        switch state {
        case .alwaysLocationUpgrade: return "location.fill"
        case .locationDenied:        return "location.slash.fill"
        case .motionDenied:          return "figure.walk.motion.trianglebadge.exclamationmark"
        case .mapLoadFailed:         return "wifi.exclamationmark"
        case .paused:                return "pause.circle.fill"
        case .failedUploads:         return "exclamationmark.icloud.fill"
        case .thermalPaused:         return "thermometer.high"
        case .offline:               return "wifi.slash"
        }
    }

    private var backgroundColor: Color {
        switch state.severity {
        case .nudge:
            return DesignTokens.Palette.signal
        case .failure:
            return DesignTokens.Palette.danger
        }
    }
}

#Preview("Attention pills — actionable") {
    VStack(alignment: .leading, spacing: DesignTokens.Space.sm) {
        NeedsAttentionPill(state: .alwaysLocationUpgrade, onTap: {})
        NeedsAttentionPill(state: .locationDenied, onTap: {})
        NeedsAttentionPill(state: .motionDenied, onTap: {})
        NeedsAttentionPill(state: .paused, onTap: {})
        NeedsAttentionPill(state: .failedUploads, onTap: {})
    }
    .padding()
    .background(DesignTokens.Palette.deep)
}

#Preview("Attention pills — informational") {
    VStack(alignment: .leading, spacing: DesignTokens.Space.sm) {
        NeedsAttentionPill(state: .thermalPaused, onTap: {})
        NeedsAttentionPill(state: .offline, onTap: {})
        NeedsAttentionPill(state: .mapLoadFailed(), onTap: {})
    }
    .padding()
    .background(DesignTokens.Palette.deep)
}
