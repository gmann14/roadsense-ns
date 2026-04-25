import SwiftUI

// MARK: - BrandChip
//
// `BrandMark` lives in `Features/DesignSystem/BrandMark.swift` (the canonical mark).
// `BrandChip` wraps it in the top-left status pill on the driving screen.

/// Top-left status pill on the driving screen. Brand mark + word mark + a pulsing
/// amber dot when actively recording. Decorative — no tap target.
///
/// Reference: `docs/reviews/2026-04-24-design-audit.md` §13.2 + §D1.
struct BrandChip: View {
    let isRecording: Bool
    var accessibilityIdentifier: String? = nil

    var body: some View {
        HStack(spacing: DesignTokens.Space.xs) {
            BrandMark(size: 24)

            Text(BrandVoice.Driving.appName)
                .font(.system(size: 15, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
                .lineLimit(1)

            if isRecording {
                PulsingDot()
                    .frame(width: 8, height: 8)
                    .padding(.leading, 2)
            }
        }
        .padding(.horizontal, DesignTokens.Space.sm)
        .padding(.vertical, 7)
        .background(
            Capsule().fill(
                LinearGradient(
                    colors: [
                        DesignTokens.Palette.deep.opacity(0.88),
                        DesignTokens.Palette.deepInk.opacity(0.82)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
        )
        .overlay(
            Capsule().strokeBorder(.white.opacity(0.18), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.25), radius: 12, y: 5)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            isRecording
                ? "\(BrandVoice.Driving.appName), recording."
                : BrandVoice.Driving.appName
        )
        .accessibilityAddTraits(.isStaticText)
        .accessibilityIdentifier(accessibilityIdentifier ?? "")
    }
}

/// Subtle amber pulse used inside `BrandChip` when recording. Respects Reduced Motion.
private struct PulsingDot: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var phase: Double = 0

    var body: some View {
        ZStack {
            if !reduceMotion {
                Circle()
                    .fill(DesignTokens.Palette.signal.opacity(0.35))
                    .scaleEffect(1 + phase * 0.7)
                    .opacity(1 - phase)
            }
            Circle()
                .fill(DesignTokens.Palette.signal)
        }
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.easeOut(duration: 1.2).repeatForever(autoreverses: false)) {
                phase = 1
            }
        }
    }
}

// MARK: - ChromeButton (top-right)

/// Single chrome button used for the settings gear in the top-right of the
/// driving screen. ~40 pt visible target with built-in tap-forgiveness.
struct ChromeButton: View {
    let systemName: String
    let accessibilityLabel: String
    var accessibilityIdentifier: String? = nil
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 40, height: 40)
                .background(.black.opacity(0.36), in: Circle())
                .overlay(Circle().strokeBorder(.white.opacity(0.16), lineWidth: 1))
                .shadow(color: .black.opacity(0.2), radius: 8, y: 3)
                .contentShape(Circle().inset(by: -8)) // §12.2.3 tap-forgiveness
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityIdentifier(accessibilityIdentifier ?? "")
    }
}

// MARK: - HeroPotholeFAB

/// The center hero FAB on the driving screen. 96-pt visible body inside a
/// 124-pt ambient progress ring. Always reads "Mark pothole" — never enters
/// a celebration lockout (per §13.3 — undo lives in `UndoChip` instead).
struct HeroPotholeFAB: View {
    let isRecording: Bool
    var accessibilityIdentifier: String? = nil
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: DesignTokens.Space.xs) {
                ZStack {
                    if isRecording {
                        AmbientRing()
                            .frame(width: 124, height: 124)
                    }

                    Circle()
                        .fill(
                            LinearGradient(
                                colors: [
                                    DesignTokens.Palette.warning,
                                    DesignTokens.Palette.danger
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .frame(width: 96, height: 96)
                        .overlay(
                            Circle().strokeBorder(.white.opacity(0.35), lineWidth: 1.5)
                        )
                        .shadow(color: .black.opacity(0.36), radius: 18, y: 9)

                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 32, weight: .bold))
                        .foregroundStyle(.white)
                        .shadow(color: .black.opacity(0.25), radius: 1, y: 1)
                }
                .contentShape(Circle().inset(by: -12)) // §12.2.3 tap-forgiveness

                Text(BrandVoice.Driving.markPotholeLabel)
                    .font(.system(.callout, design: .rounded, weight: .bold))
                    .foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.6), radius: 4, y: 1)
                    .dynamicTypeSize(...DynamicTypeSize.accessibility1)
            }
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(BrandVoice.Driving.markPotholeAccessibilityLabel)
        .accessibilityHint(BrandVoice.Driving.markPotholeAccessibilityHint)
        .accessibilityAddTraits(.isButton)
        .accessibilityIdentifier(accessibilityIdentifier ?? "")
    }
}

/// Recording-alive indicator orbiting the hero FAB. ~80° teal arc rotates slowly.
/// No goal semantic — just a heartbeat. Respects Reduced Motion (static arc when on).
struct AmbientRing: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var rotation: Double = 0

    var body: some View {
        ZStack {
            Circle()
                .stroke(Color.white.opacity(0.14), lineWidth: 6)

            Circle()
                .trim(from: 0, to: 0.22)
                .stroke(
                    DesignTokens.Palette.smooth,
                    style: StrokeStyle(lineWidth: 6, lineCap: .round)
                )
                .rotationEffect(.degrees(rotation - 90))
                .onAppear {
                    guard !reduceMotion else { return }
                    withAnimation(.linear(duration: 4).repeatForever(autoreverses: false)) {
                        rotation = 360
                    }
                }
        }
    }
}

// MARK: - UndoChip + CountdownRing

/// Floating pill that appears for 5 seconds after a pothole is marked.
/// Tapping undoes the most recent mark. The hero FAB stays a "Mark pothole"
/// button continuously so consecutive marks 30 m apart are never blocked.
///
/// Reference: §13.3 of the audit.
struct UndoChip: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: DesignTokens.Space.xs) {
                CountdownRing(duration: 5)
                    .frame(width: 16, height: 16)

                Text(BrandVoice.Driving.undoLastMark)
                    .font(.system(.footnote, design: .rounded, weight: .semibold))
                    .foregroundStyle(.white)
                    .dynamicTypeSize(...DynamicTypeSize.accessibility1)
            }
            .padding(.horizontal, DesignTokens.Space.md)
            .padding(.vertical, 9)
            .background(
                Capsule().fill(Color.black.opacity(0.72))
            )
            .overlay(
                Capsule().strokeBorder(.white.opacity(0.18), lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.32), radius: 12, y: 5)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(BrandVoice.Driving.undoLastMark)
        .accessibilityHint(BrandVoice.Driving.undoAccessibilityHint)
    }
}

/// 5-second receding arc inside `UndoChip`. Visualizes the undo window.
/// On Reduced Motion, the arc renders at half (a frozen "halfway" indicator)
/// instead of animating.
struct CountdownRing: View {
    let duration: Double

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var remaining: Double = 1.0

    var body: some View {
        ZStack {
            Circle()
                .stroke(Color.white.opacity(0.18), lineWidth: 2)

            Circle()
                .trim(from: 0, to: reduceMotion ? 0.5 : remaining)
                .stroke(
                    DesignTokens.Palette.signal,
                    style: StrokeStyle(lineWidth: 2, lineCap: .round)
                )
                .rotationEffect(.degrees(-90))
        }
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.linear(duration: duration)) {
                remaining = 0
            }
        }
    }
}

// MARK: - SecondaryFAB

/// 56-pt secondary action FAB used for Photo and Stats on the driving screen.
/// Visually subordinate to the hero FAB; same size for both so they read as
/// a symmetric pair flanking the center.
struct SecondaryFAB: View {
    let systemName: String
    let label: String
    let accessibilityLabel: String
    let accessibilityHint: String?
    let accessibilityIdentifier: String?
    let action: () -> Void

    init(
        systemName: String,
        label: String,
        accessibilityLabel: String? = nil,
        accessibilityHint: String? = nil,
        accessibilityIdentifier: String? = nil,
        action: @escaping () -> Void
    ) {
        self.systemName = systemName
        self.label = label
        self.accessibilityLabel = accessibilityLabel ?? label
        self.accessibilityHint = accessibilityHint
        self.accessibilityIdentifier = accessibilityIdentifier
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            VStack(spacing: DesignTokens.Space.xs) {
                Image(systemName: systemName)
                    .font(.system(size: 21, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 56, height: 56)
                    .background(
                        Circle().fill(DesignTokens.Palette.deep)
                    )
                    .overlay(
                        Circle().strokeBorder(.white.opacity(0.22), lineWidth: 1)
                    )
                    .shadow(color: .black.opacity(0.28), radius: 12, y: 5)
                    .contentShape(Circle().inset(by: -10)) // §12.2.3 tap-forgiveness

                Text(label)
                    .font(.system(.footnote, design: .rounded, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.88))
                    .shadow(color: .black.opacity(0.5), radius: 3, y: 1)
                    .dynamicTypeSize(...DynamicTypeSize.accessibility1)
            }
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityHint(accessibilityHint ?? "")
        .accessibilityAddTraits(.isButton)
        .accessibilityIdentifier(accessibilityIdentifier ?? "")
    }
}

// MARK: - Center stage content

/// Pro-social headline shown on the driving screen between drives. Replaces
/// the previous "View stats" primary action — see §7.D5.
struct IdleStatWell: View {
    let kmThisMonth: Double
    let communityKmThisWeek: Double
    let communityDriversThisWeek: Int

    var body: some View {
        VStack(alignment: .center, spacing: 6) {
            Text(BrandVoice.Stats.yourContributionEyebrow)
                .font(.system(size: 10, weight: .bold))
                .tracking(1.3)
                .foregroundStyle(.white.opacity(0.7))

            Text(formattedKm)
                .font(.system(size: 38, weight: .bold, design: .rounded).monospacedDigit())
                .foregroundStyle(.white)
                .shadow(color: .black.opacity(0.25), radius: 4, y: 1)
                .dynamicTypeSize(...DynamicTypeSize.accessibility1)

            Text(BrandVoice.Stats.thisMonthMappedSubtitle)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.white.opacity(0.85))
                .multilineTextAlignment(.center)

            if communityKmThisWeek > 0 || communityDriversThisWeek > 0 {
                Text(BrandVoice.Stats.communityThisWeek(
                    km: communityKmThisWeek,
                    drivers: communityDriversThisWeek
                ))
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.white.opacity(0.7))
                .multilineTextAlignment(.center)
                .padding(.top, 2)
            }
        }
        .frame(maxWidth: 240)
        .padding(.horizontal, DesignTokens.Space.lg)
        .padding(.vertical, DesignTokens.Space.md)
        .accessibilityElement(children: .combine)
    }

    private var formattedKm: String {
        let kmString = kmThisMonth.formatted(.number.precision(.fractionLength(kmThisMonth < 10 ? 1 : 0)))
        return "\(kmString) km"
    }
}

/// Empty-state illustration on the map before the user has any drives.
struct FirstRunIllustration: View {
    var body: some View {
        VStack(spacing: DesignTokens.Space.md) {
            ZStack {
                Circle()
                    .strokeBorder(
                        Color.white.opacity(0.18),
                        style: StrokeStyle(lineWidth: 1, dash: [4, 8])
                    )
                    .frame(width: 160, height: 160)
                Circle()
                    .fill(DesignTokens.Palette.signal.opacity(0.22))
                    .frame(width: 92, height: 92)
                Image(systemName: "car.side.fill")
                    .font(.system(size: 38, weight: .regular))
                    .foregroundStyle(.white)
            }

            VStack(spacing: 6) {
                Text(BrandVoice.Driving.firstRunTitle)
                    .font(.system(size: 20, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                    .dynamicTypeSize(...DynamicTypeSize.accessibility1)

                Text(BrandVoice.Driving.firstRunBody)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(.white.opacity(0.8))
                    .multilineTextAlignment(.center)
            }
        }
        .padding(DesignTokens.Space.xl)
        .accessibilityElement(children: .combine)
    }
}
