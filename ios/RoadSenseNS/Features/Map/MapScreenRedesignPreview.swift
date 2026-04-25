import SwiftUI

/// PREVIEW-ONLY mockup proposing the redesigned driving screen.
///
/// Not wired to `AppModel`, Mapbox, or live data. Pure SwiftUI primitives + mock state
/// so it compiles with zero environment setup. Open any `#Preview` at the bottom of
/// this file to see the proposal.
///
/// Rationale: `docs/reviews/2026-04-24-design-audit.md` §6 and §D1.
///
/// What this demonstrates:
/// - Top-left brand chip (mark + name + recording pulse)
/// - Top-right minimal stats/settings chrome
/// - Hero pothole FAB (96×96) with ambient progress ring + live countdown on mark
/// - Secondary camera FAB, visible only when "stopped or walking"
/// - Sketched road ribbon behind the FAB area (community map would sit below)
/// - Idle pro-social readout (replaces the "View stats" primary button)
/// - Custom canvas-drawn brand mark (chevron stitch)
struct MapScreenRedesignPreview: View {
    enum MockScenario: String, CaseIterable, Identifiable {
        case firstRun = "First run"
        case idle = "Idle (between drives)"
        case activeDrive = "Active drive"
        case stopped = "Active · stopped"
        case justMarked = "Just marked a pothole"

        var id: String { rawValue }
    }

    @State private var scenario: MockScenario = .activeDrive
    @State private var tick: Date = .now

    // Timeline drives the drifting ribbon + ring animation.
    var body: some View {
        VStack(spacing: 0) {
            stage
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            debugScenarioPicker
        }
    }

    private var stage: some View {
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
                    .padding(.bottom, DesignTokens.Space.xl)
            }
        }
    }

    // MARK: - Top bar

    private var topBar: some View {
        HStack(alignment: .center, spacing: DesignTokens.Space.sm) {
            BrandChip(isRecording: isRecording)

            Spacer(minLength: DesignTokens.Space.sm)

            HStack(spacing: DesignTokens.Space.xs) {
                ChromeButton(systemName: "chart.bar.fill")
                ChromeButton(systemName: "gearshape.fill")
            }
        }
    }

    // MARK: - Center stage

    @ViewBuilder
    private var centerStageContent: some View {
        switch scenario {
        case .firstRun:
            FirstRunIllustration()
                .transition(.opacity)
        case .idle:
            IdleStatWell()
                .transition(.opacity)
        case .activeDrive, .stopped, .justMarked:
            Color.clear
        }
    }

    // MARK: - Bottom FAB cluster

    private var bottomFabCluster: some View {
        ZStack {
            // Secondary camera FAB is conditional + offset to the right of the hero
            if showsCameraFab {
                SecondaryCameraFAB()
                    .offset(x: 92, y: 6)
                    .transition(.scale(scale: 0.4).combined(with: .opacity))
            }

            HeroPotholeFAB(
                progress: ringProgress,
                fabState: fabStateForScenario
            )
        }
        .animation(DesignTokens.Motion.standard, value: scenario)
    }

    // MARK: - Scenario wiring

    private var isRecording: Bool {
        switch scenario {
        case .activeDrive, .stopped, .justMarked: return true
        case .firstRun, .idle: return false
        }
    }

    private var showsCameraFab: Bool {
        scenario == .stopped
    }

    /// How full the ambient ring is. 0...1.
    private var ringProgress: Double {
        switch scenario {
        case .firstRun, .idle: return 0
        case .activeDrive, .justMarked: return 0.42
        case .stopped: return 0.42
        }
    }

    private var fabStateForScenario: HeroPotholeFAB.FABState {
        scenario == .justMarked ? .justMarked : .idle
    }

    // MARK: - Debug picker

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

// MARK: - Brand chip & mark

/// 28pt brand mark drawn with Canvas. A single amber chevron over a deep teal disc.
/// Not a locked logo — this is the "stop using `SF Symbols` as a placeholder" substitute
/// from §1.3 of the audit.
struct BrandMark: View {
    let size: CGFloat

    var body: some View {
        Canvas { ctx, canvasSize in
            let rect = CGRect(origin: .zero, size: canvasSize)
            ctx.fill(Path(ellipseIn: rect), with: .color(DesignTokens.Palette.deep))

            let w = canvasSize.width
            let h = canvasSize.height
            let strokeWidth = max(w * 0.13, 2)
            let cx = w / 2
            let cy = h * 0.58
            let chevronHalfW = w * 0.26
            let chevronH = h * 0.18

            var chevron = Path()
            chevron.move(to: CGPoint(x: cx - chevronHalfW, y: cy + chevronH / 2))
            chevron.addLine(to: CGPoint(x: cx, y: cy - chevronH / 2))
            chevron.addLine(to: CGPoint(x: cx + chevronHalfW, y: cy + chevronH / 2))
            ctx.stroke(
                chevron,
                with: .color(DesignTokens.Palette.signal),
                style: StrokeStyle(lineWidth: strokeWidth, lineCap: .round, lineJoin: .round)
            )

            // Small accent dot above — the "pin" / road marker suggestion
            let dotRadius = w * 0.06
            let dotRect = CGRect(
                x: cx - dotRadius,
                y: cy - chevronH / 2 - dotRadius * 2.4,
                width: dotRadius * 2,
                height: dotRadius * 2
            )
            ctx.fill(Path(ellipseIn: dotRect), with: .color(DesignTokens.Palette.signal))
        }
        .frame(width: size, height: size)
        .accessibilityLabel("RoadSense NS")
    }
}

/// The top-left brand chip with a pulsing dot when recording.
struct BrandChip: View {
    let isRecording: Bool

    var body: some View {
        HStack(spacing: DesignTokens.Space.xs) {
            BrandMark(size: 24)

            Text("RoadSense")
                .font(.system(size: 15, weight: .bold, design: .rounded))
                .foregroundStyle(.white)

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
    }
}

struct PulsingDot: View {
    @State private var phase: Double = 0

    var body: some View {
        ZStack {
            Circle()
                .fill(DesignTokens.Palette.signal.opacity(0.35))
                .scaleEffect(1 + phase * 0.7)
                .opacity(1 - phase)
            Circle()
                .fill(DesignTokens.Palette.signal)
        }
        .onAppear {
            withAnimation(.easeOut(duration: 1.2).repeatForever(autoreverses: false)) {
                phase = 1
            }
        }
    }
}

// MARK: - Chrome buttons

struct ChromeButton: View {
    let systemName: String

    var body: some View {
        Button(action: {}) {
            Image(systemName: systemName)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 40, height: 40)
                .background(.black.opacity(0.36), in: Circle())
                .overlay(Circle().strokeBorder(.white.opacity(0.16), lineWidth: 1))
                .shadow(color: .black.opacity(0.2), radius: 8, y: 3)
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Hero pothole FAB + ring

struct HeroPotholeFAB: View {
    enum FABState {
        case idle
        case justMarked
    }

    let progress: Double // 0...1 — ambient drive progress
    let fabState: FABState

    var body: some View {
        VStack(spacing: DesignTokens.Space.xs) {
            ZStack {
                // Outer ambient progress ring (teal)
                ProgressRing(progress: progress)
                    .frame(width: 124, height: 124)

                // Undo countdown — shown during justMarked
                if fabState == .justMarked {
                    CountdownRing(duration: 5)
                        .frame(width: 124, height: 124)
                        .transition(.opacity)
                }

                // FAB body
                Circle()
                    .fill(
                        LinearGradient(
                            colors: fabState == .justMarked
                                ? [DesignTokens.Palette.success, DesignTokens.Palette.smooth]
                                : [DesignTokens.Palette.warning, DesignTokens.Palette.danger],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: 96, height: 96)
                    .overlay(
                        Circle().strokeBorder(.white.opacity(0.35), lineWidth: 1.5)
                    )
                    .shadow(color: .black.opacity(0.36), radius: 18, y: 9)

                Image(systemName: fabState == .justMarked ? "checkmark" : "exclamationmark.triangle.fill")
                    .font(.system(size: 32, weight: .bold))
                    .foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.25), radius: 1, y: 1)
            }

            Text(fabState == .justMarked ? "Marked!" : "Pothole")
                .font(.system(size: 15, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
                .shadow(color: .black.opacity(0.6), radius: 4, y: 1)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(fabState == .justMarked ? "Marked — undo available" : "Mark pothole")
        .accessibilityHint("Queues a pothole report using your current location.")
    }
}

struct ProgressRing: View {
    let progress: Double

    var body: some View {
        ZStack {
            Circle()
                .stroke(Color.white.opacity(0.14), lineWidth: 6)

            Circle()
                .trim(from: 0, to: max(progress, 0.001))
                .stroke(
                    DesignTokens.Palette.smooth,
                    style: StrokeStyle(lineWidth: 6, lineCap: .round)
                )
                .rotationEffect(.degrees(-90))
                .animation(DesignTokens.Motion.map, value: progress)
        }
    }
}

/// 5-second receding arc animating from full to empty. Visual for the undo window.
struct CountdownRing: View {
    let duration: Double
    @State private var remaining: Double = 1.0

    var body: some View {
        Circle()
            .trim(from: 0, to: remaining)
            .stroke(
                DesignTokens.Palette.signal,
                style: StrokeStyle(lineWidth: 8, lineCap: .round)
            )
            .rotationEffect(.degrees(-90))
            .onAppear {
                withAnimation(.linear(duration: duration)) {
                    remaining = 0
                }
            }
    }
}

// MARK: - Secondary camera FAB

struct SecondaryCameraFAB: View {
    var body: some View {
        Button(action: {}) {
            Image(systemName: "camera.viewfinder")
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 60, height: 60)
                .background(
                    Circle().fill(DesignTokens.Palette.deep)
                )
                .overlay(
                    Circle().strokeBorder(.white.opacity(0.24), lineWidth: 1.5)
                )
                .shadow(color: .black.opacity(0.3), radius: 14, y: 6)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Add photo")
        .accessibilityHint("Available when you're stopped or walking.")
    }
}

// MARK: - Center content

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
                Text("Drive normally.")
                    .font(.system(size: 20, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)

                Text("Your first road ribbon shows up\nafter the next sync.")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(.white.opacity(0.8))
                    .multilineTextAlignment(.center)
            }
        }
        .padding(DesignTokens.Space.xl)
    }
}

struct IdleStatWell: View {
    var body: some View {
        VStack(alignment: .center, spacing: DesignTokens.Space.md) {
            Text("YOUR CONTRIBUTION")
                .font(.system(size: 10, weight: .bold))
                .tracking(1.3)
                .foregroundStyle(.white.opacity(0.7))

            // Placeholder for Plex Mono — swap to Font.custom("IBMPlexMono-Bold", ...) when bundled
            Text("47 km")
                .font(.system(size: 56, weight: .bold, design: .rounded).monospacedDigit())
                .foregroundStyle(.white)
                .shadow(color: .black.opacity(0.25), radius: 6, y: 2)

            Text("of Nova Scotia mapped this month.")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(.white.opacity(0.88))

            Divider()
                .overlay(Color.white.opacity(0.15))
                .padding(.vertical, DesignTokens.Space.xs)
                .frame(width: 120)

            Text("Plus 318 km from 812 drivers near you.")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.white.opacity(0.72))
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: 320)
        .padding(DesignTokens.Space.xl)
    }
}

// MARK: - Map placeholder layer

/// Stands in for Mapbox during preview. A warm linear gradient + a hand-drawn
/// road-ribbon path suggesting "the last stretch you drove" fading away.
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

            // Faux contour lines for the "field atlas" vibe
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

            // Road ribbon, drawn only when there's a drive in progress/memory
            if showsRibbon {
                RoadRibbonSketch()
                    .opacity(0.85)
            }
        }
    }

    private var showsRibbon: Bool {
        switch scenario {
        case .activeDrive, .stopped, .justMarked: return true
        case .firstRun, .idle: return false
        }
    }
}

/// A curved path painted with ramp colors from green → amber → red along its length,
/// suggesting the last several km of driven road with roughness. Placeholder for a
/// real Mapbox-layer implementation pulling from `pendingDriveCoordinates`.
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

            // "You are here" dot at the head of the ribbon
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

#Preview("Active · stopped (camera FAB)") {
    PreviewContainer(scenario: .stopped)
}

#Preview("Just marked (celebration)") {
    PreviewContainer(scenario: .justMarked)
}

#Preview("Interactive scenario switcher") {
    MapScreenRedesignPreview()
}

/// Wrapper that starts the preview in a specific scenario and hides the debug picker
/// so single-scenario previews look clean.
struct PreviewContainer: View {
    let scenario: MapScreenRedesignPreview.MockScenario

    var body: some View {
        StaticPreview(scenario: scenario)
    }
}

struct StaticPreview: View {
    let scenario: MapScreenRedesignPreview.MockScenario

    var body: some View {
        ZStack {
            MapPlaceholderLayer(scenario: scenario)
                .ignoresSafeArea()

            VStack(spacing: 0) {
                HStack(alignment: .center, spacing: DesignTokens.Space.sm) {
                    BrandChip(isRecording: isRecording)
                    Spacer(minLength: DesignTokens.Space.sm)
                    HStack(spacing: DesignTokens.Space.xs) {
                        ChromeButton(systemName: "chart.bar.fill")
                        ChromeButton(systemName: "gearshape.fill")
                    }
                }
                .padding(.horizontal, DesignTokens.Space.md)
                .padding(.top, DesignTokens.Space.sm)

                Spacer(minLength: 0)

                centerStageContent

                Spacer(minLength: 0)

                ZStack {
                    if showsCameraFab {
                        SecondaryCameraFAB()
                            .offset(x: 92, y: 6)
                    }
                    HeroPotholeFAB(progress: ringProgress, fabState: fabStateForScenario)
                }
                .padding(.bottom, DesignTokens.Space.xl)
            }
        }
    }

    @ViewBuilder
    private var centerStageContent: some View {
        switch scenario {
        case .firstRun: FirstRunIllustration()
        case .idle: IdleStatWell()
        default: Color.clear
        }
    }

    private var isRecording: Bool {
        switch scenario {
        case .activeDrive, .stopped, .justMarked: return true
        default: return false
        }
    }

    private var showsCameraFab: Bool {
        scenario == .stopped
    }

    private var ringProgress: Double {
        switch scenario {
        case .firstRun, .idle: return 0
        default: return 0.42
        }
    }

    private var fabStateForScenario: HeroPotholeFAB.FABState {
        scenario == .justMarked ? .justMarked : .idle
    }
}
