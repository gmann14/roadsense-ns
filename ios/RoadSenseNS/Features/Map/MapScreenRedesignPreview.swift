import SwiftUI

/// PREVIEW-ONLY mockup demonstrating the redesigned driving screen.
///
/// Uses the **production** components from `DrivingScreenComponents.swift` so the
/// previews stay aligned with what actually ships. Mock-only helpers
/// (`MapPlaceholderLayer`, `RoadRibbonSketch`) stand in for Mapbox during preview.
///
/// Reference: `docs/reviews/2026-04-24-design-audit.md` §6, §13.
struct MapScreenRedesignPreview: View {
    enum MockScenario: String, CaseIterable, Identifiable {
        case firstRun = "First run"
        case idle = "Idle (between drives)"
        case activeDrive = "Active drive"
        case justMarked = "Just marked a pothole"

        var id: String { rawValue }
    }

    @State private var scenario: MockScenario = .activeDrive

    var body: some View {
        VStack(spacing: 0) {
            stage
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            debugScenarioPicker
        }
    }

    private var stage: some View {
        StaticPreview(scenario: scenario)
    }

    private var debugScenarioPicker: some View {
        VStack(spacing: DesignTokens.Space.xs) {
            Text("PREVIEW SCENARIO")
                .font(.system(size: 10, weight: .bold))
                .tracking(1.2)
                .foregroundStyle(DesignTokens.Palette.inkMuted)

            Picker("Scenario", selection: $scenario) {
                ForEach(MockScenario.allCases) { scenario in
                    Text(scenario.rawValue).tag(scenario)
                }
            }
            .pickerStyle(.segmented)
        }
        .padding(DesignTokens.Space.md)
        .background(DesignTokens.Palette.canvasSunken)
    }
}

// MARK: - Preview-only map placeholder

/// Stands in for Mapbox during preview. A warm linear gradient + a hand-drawn
/// road-ribbon path suggesting "the last stretch you drove" fading away.
/// Production renders Mapbox vector tiles instead.
struct MapPlaceholderLayer: View {
    let scenario: MapScreenRedesignPreview.MockScenario

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [
                    DesignTokens.Palette.deep,
                    DesignTokens.Palette.deepInk
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )

            Canvas { ctx, size in
                let linePaint = GraphicsContext.Shading.color(Color.white.opacity(0.05))
                for i in 0..<10 {
                    var path = Path()
                    let y = CGFloat(i) * (size.height / 10) + CGFloat(i % 3) * 6
                    path.move(to: CGPoint(x: -10, y: y))
                    path.addCurve(
                        to: CGPoint(x: size.width + 10, y: y + 28),
                        control1: CGPoint(x: size.width * 0.3, y: y + 40),
                        control2: CGPoint(x: size.width * 0.7, y: y - 20)
                    )
                    ctx.stroke(path, with: linePaint, lineWidth: 1)
                }
            }

            if showsRibbon {
                RoadRibbonSketch()
                    .opacity(0.85)
            }
        }
    }

    private var showsRibbon: Bool {
        switch scenario {
        case .activeDrive, .justMarked: return true
        case .firstRun, .idle: return false
        }
    }
}

/// Mockup-only ribbon sketch. Production renders this from real
/// `pendingDriveCoordinates` via a Mapbox `LineLayer`.
struct RoadRibbonSketch: View {
    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height

            Path { path in
                path.move(to: CGPoint(x: w * 0.12, y: h * 0.86))
                path.addCurve(
                    to: CGPoint(x: w * 0.5, y: h * 0.58),
                    control1: CGPoint(x: w * 0.26, y: h * 0.72),
                    control2: CGPoint(x: w * 0.34, y: h * 0.56)
                )
                path.addCurve(
                    to: CGPoint(x: w * 0.92, y: h * 0.32),
                    control1: CGPoint(x: w * 0.68, y: h * 0.60),
                    control2: CGPoint(x: w * 0.84, y: h * 0.42)
                )
            }
            .stroke(
                LinearGradient(
                    colors: [
                        DesignTokens.Palette.smooth,
                        DesignTokens.Palette.smooth,
                        DesignTokens.Palette.fair,
                        DesignTokens.Palette.rough,
                        DesignTokens.Palette.veryRough
                    ],
                    startPoint: .bottomLeading,
                    endPoint: .topTrailing
                ),
                style: StrokeStyle(lineWidth: 8, lineCap: .round, lineJoin: .round)
            )

            Circle()
                .fill(Color.white)
                .frame(width: 14, height: 14)
                .overlay(Circle().strokeBorder(DesignTokens.Palette.deep, lineWidth: 3))
                .position(x: w * 0.92, y: h * 0.32)
                .shadow(color: .black.opacity(0.3), radius: 6, y: 2)
        }
    }
}

// MARK: - Previews

#Preview("Active drive (hero moment)") {
    PreviewContainer(scenario: .activeDrive)
}

#Preview("Idle · pro-social readout") {
    PreviewContainer(scenario: .idle)
}

#Preview("First run") {
    PreviewContainer(scenario: .firstRun)
}

#Preview("Just marked (celebration)") {
    PreviewContainer(scenario: .justMarked)
}

#Preview("Interactive scenario switcher") {
    MapScreenRedesignPreview()
}

struct PreviewContainer: View {
    let scenario: MapScreenRedesignPreview.MockScenario

    var body: some View {
        StaticPreview(scenario: scenario)
    }
}

/// Self-contained preview composition using **production** driving-screen
/// components. The render-test pipeline writes PNGs from this view.
struct StaticPreview: View {
    let scenario: MapScreenRedesignPreview.MockScenario

    var body: some View {
        ZStack {
            MapPlaceholderLayer(scenario: scenario)
                .ignoresSafeArea()

            VStack(spacing: 0) {
                topBar
                    .padding(.horizontal, DesignTokens.Space.md)
                    .padding(.top, DesignTokens.Space.sm)

                Spacer(minLength: 0)

                centerStageContent

                Spacer(minLength: 0)

                bottomFabCluster
                    .padding(.horizontal, DesignTokens.Space.xl)
                    .padding(.bottom, DesignTokens.Space.xl)
            }
        }
    }

    private var topBar: some View {
        HStack(alignment: .center, spacing: DesignTokens.Space.sm) {
            BrandChip(isRecording: isRecording)
            Spacer(minLength: DesignTokens.Space.sm)
            ChromeButton(systemName: "gearshape.fill", accessibilityLabel: "Settings", action: {})
        }
    }

    @ViewBuilder
    private var centerStageContent: some View {
        switch scenario {
        case .firstRun:
            FirstRunIllustration()
        case .idle:
            IdleStatWell(
                kmThisMonth: 47,
                communityKmThisWeek: 318,
                communityDriversThisWeek: 812,
                onDismiss: {}
            )
        default:
            Color.clear
        }
    }

    private var bottomFabCluster: some View {
        VStack(spacing: DesignTokens.Space.md) {
            if scenario == .justMarked {
                UndoChip(action: {})
            }

            HStack(alignment: .bottom, spacing: 0) {
                Spacer()
                SecondaryFAB(
                    systemName: "camera.viewfinder",
                    label: BrandVoice.Driving.photoLabel,
                    accessibilityLabel: BrandVoice.Driving.photoAccessibilityLabel,
                    accessibilityHint: BrandVoice.Driving.photoAccessibilityHint,
                    action: {}
                )
                Spacer()
                HeroPotholeFAB(isRecording: isRecording, action: {})
                Spacer()
                SecondaryFAB(
                    systemName: "chart.bar.fill",
                    label: BrandVoice.Driving.statsLabel,
                    accessibilityLabel: BrandVoice.Driving.statsAccessibilityLabel,
                    action: {}
                )
                Spacer()
            }
        }
    }

    private var isRecording: Bool {
        switch scenario {
        case .activeDrive, .justMarked: return true
        default: return false
        }
    }
}
