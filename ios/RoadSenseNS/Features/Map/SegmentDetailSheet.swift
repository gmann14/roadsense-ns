import SwiftUI

struct SegmentDetailSheet: View {
    let segment: SegmentDetailResponse
    var onSubmitPotholeAction: (SegmentPothole, PotholeActionType) -> PotholeActionSubmissionResult = { _, _ in
        .unavailableLocation
    }
    var onAddPhoto: (UUID?) -> Void = { _ in }

    @State private var followUpFeedback: FollowUpFeedback?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DesignTokens.Space.lg) {
                hero
                chipRow
                if let followUpFeedback {
                    followUpFeedbackBanner(followUpFeedback)
                        .task(id: followUpFeedback.id) {
                            try? await Task.sleep(for: followUpFeedback.dismissDelay)
                            guard self.followUpFeedback?.id == followUpFeedback.id else { return }
                            withAnimation(DesignTokens.Motion.standard) {
                                self.followUpFeedback = nil
                            }
                        }
                }
                trendCard
                trustCard
                potholesCard
                metadataCard
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, DesignTokens.Space.xl)
            .padding(.top, DesignTokens.Space.lg)
            .padding(.bottom, DesignTokens.Space.xxxl)
        }
        .background(backgroundGradient.ignoresSafeArea())
    }

    private var backgroundGradient: some View {
        LinearGradient(
            colors: [DesignTokens.Palette.canvas, DesignTokens.Palette.canvasSunken],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    // MARK: - Hero

    private var hero: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Space.md) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: DesignTokens.Space.xs) {
                    Text(segment.municipality.uppercased())
                        .font(DesignTokens.TypeStyle.eyebrow)
                        .tracking(1.3)
                        .foregroundStyle(DesignTokens.Palette.inkMuted)
                        .accessibilityIdentifier("segmentDetail.municipality")

                    Text(segment.roadName)
                        .font(DesignTokens.TypeStyle.title)
                        .foregroundStyle(DesignTokens.Palette.ink)
                        .accessibilityIdentifier("segmentDetail.roadName")

                    Text(categoryCopy)
                        .font(DesignTokens.TypeStyle.callout)
                        .foregroundStyle(DesignTokens.Palette.inkMuted)
                        .accessibilityIdentifier("segmentDetail.categoryCopy")
                }

                Spacer(minLength: DesignTokens.Space.md)

                scoreMedallion
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(DesignTokens.Space.xl)
        .background(
            RoundedRectangle(cornerRadius: DesignTokens.Radius.lg, style: .continuous)
                .fill(DesignTokens.Palette.surface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: DesignTokens.Radius.lg, style: .continuous)
                .strokeBorder(DesignTokens.Palette.border, lineWidth: 1)
        )
        .shadow(color: Color.black.opacity(0.06), radius: 22, y: 12)
    }

    private var scoreMedallion: some View {
        let tint = DesignTokens.rampColor(for: segment.aggregate.category)
        return ZStack {
            Circle()
                .fill(tint.opacity(0.14))
                .frame(width: 92, height: 92)
            Circle()
                .stroke(tint.opacity(0.32), lineWidth: 2)
                .frame(width: 92, height: 92)
            VStack(spacing: 2) {
                Text(segment.aggregate.avgRoughnessScore.formatted(.number.precision(.fractionLength(2))))
                    .font(.system(size: 22, weight: .bold, design: .rounded).monospacedDigit())
                    .foregroundStyle(DesignTokens.Palette.ink)
                    .accessibilityIdentifier("segmentDetail.score")
                Text("score")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(DesignTokens.Palette.inkMuted)
                    .textCase(.uppercase)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var chipRow: some View {
        HStack(spacing: DesignTokens.Space.sm) {
            chip(
                label: "CONFIDENCE",
                value: segment.aggregate.confidence.displayConfidenceLabel,
                tint: DesignTokens.Palette.deep
            )
            chip(
                label: "TREND",
                value: segment.aggregate.trend.displayTrendLabel,
                tint: trendTint
            )
            chip(
                label: "UPDATED",
                value: updatedLabel,
                tint: DesignTokens.Palette.inkMuted
            )
        }
    }

    private func chip(label: String, value: String, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.system(size: 10, weight: .bold))
                .tracking(1.2)
                .foregroundStyle(tint)
            Text(value)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(DesignTokens.Palette.ink)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(DesignTokens.Space.sm)
        .background(
            RoundedRectangle(cornerRadius: DesignTokens.Radius.sm, style: .continuous)
                .fill(tint.opacity(0.08))
        )
        .overlay(
            RoundedRectangle(cornerRadius: DesignTokens.Radius.sm, style: .continuous)
                .strokeBorder(tint.opacity(0.18), lineWidth: 1)
        )
    }

    // MARK: - Trend card

    private var trendCard: some View {
        sectionCard(title: "30-day trend") {
            VStack(alignment: .leading, spacing: DesignTokens.Space.md) {
                if let recent = segment.aggregate.scoreLast30D, let prior = segment.aggregate.score30To60D {
                    sparkline(recent: recent, prior: prior)
                    HStack(spacing: DesignTokens.Space.xl) {
                        trendStat(label: "Last 30d", value: recent, tint: DesignTokens.rampColor(for: segment.aggregate.category))
                        trendStat(label: "Prior 30d", value: prior, tint: DesignTokens.Palette.inkMuted)
                        trendStat(label: "Change", value: recent - prior, tint: trendTint, isDelta: true)
                    }
                } else {
                    Text("Trend history will appear after more drivers contribute passes on this segment.")
                        .font(.system(size: 14))
                        .foregroundStyle(DesignTokens.Palette.inkMuted)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private func sparkline(recent: Double, prior: Double) -> some View {
        let points = [prior, (prior + recent) / 2, recent]
        let tint = DesignTokens.rampColor(for: segment.aggregate.category)
        return GeometryReader { proxy in
            let maxValue = max(points.max() ?? 1, 0.01)
            let width = proxy.size.width
            let height = proxy.size.height
            let step = width / CGFloat(points.count - 1)

            ZStack {
                Path { path in
                    for (index, value) in points.enumerated() {
                        let x = CGFloat(index) * step
                        let y = height - (CGFloat(value / maxValue) * height * 0.85) - 4
                        if index == 0 {
                            path.move(to: CGPoint(x: x, y: y))
                        } else {
                            path.addLine(to: CGPoint(x: x, y: y))
                        }
                    }
                }
                .stroke(tint, style: StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round))

                ForEach(Array(points.enumerated()), id: \.offset) { index, value in
                    let x = CGFloat(index) * step
                    let y = height - (CGFloat(value / maxValue) * height * 0.85) - 4
                    Circle()
                        .fill(tint)
                        .frame(width: 8, height: 8)
                        .position(x: x, y: y)
                }
            }
        }
        .frame(height: 64)
        .padding(.horizontal, 4)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: DesignTokens.Radius.sm, style: .continuous)
                .fill(DesignTokens.Palette.canvasSunken)
        )
        .accessibilityLabel("Sparkline showing roughness history")
    }

    private func trendStat(label: String, value: Double, tint: Color, isDelta: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label.uppercased())
                .font(.system(size: 10, weight: .bold))
                .tracking(1.1)
                .foregroundStyle(DesignTokens.Palette.inkMuted)
            Text(isDelta ? signedString(value) : value.formatted(.number.precision(.fractionLength(2))))
                .font(.system(size: 17, weight: .semibold, design: .rounded).monospacedDigit())
                .foregroundStyle(tint)
        }
    }

    private func signedString(_ value: Double) -> String {
        let magnitude = abs(value).formatted(.number.precision(.fractionLength(2)))
        if value > 0.005 {
            return "+" + magnitude
        } else if value < -0.005 {
            return "−" + magnitude
        }
        return "±" + magnitude
    }

    // MARK: - Trust card

    private var trustCard: some View {
        sectionCard(title: "Trust") {
            VStack(alignment: .leading, spacing: DesignTokens.Space.sm) {
                trustRow(
                    label: "Readings",
                    value: "\(segment.aggregate.totalReadings)"
                )
                Divider().overlay(DesignTokens.Palette.border)
                trustRow(
                    label: "Unique contributors",
                    value: "\(segment.aggregate.uniqueContributors)"
                )
                Divider().overlay(DesignTokens.Palette.border)
                trustRow(
                    label: "Potholes reported",
                    value: "\(segment.aggregate.potholeCount)",
                    valueTint: segment.aggregate.potholeCount > 0 ? DesignTokens.Palette.warning : DesignTokens.Palette.ink
                )

                Text(segment.aggregate.confidence.displayConfidenceExplanation)
                    .font(.system(size: 13))
                    .foregroundStyle(DesignTokens.Palette.inkMuted)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, DesignTokens.Space.xs)
            }
        }
    }

    // MARK: - Potholes card

    private var potholesCard: some View {
        sectionCard(title: "Pothole updates") {
            VStack(alignment: .leading, spacing: DesignTokens.Space.md) {
                if segment.potholes.isEmpty {
                    Text("No nearby pothole markers are available for follow-up on this segment yet.")
                        .font(.system(size: 14))
                        .foregroundStyle(DesignTokens.Palette.inkMuted)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    Text("Help verify whether an existing pothole is still there or looks fixed.")
                        .font(.system(size: 13))
                        .foregroundStyle(DesignTokens.Palette.inkMuted)
                        .fixedSize(horizontal: false, vertical: true)

                    Button {
                        onAddPhoto(segment.id)
                    } label: {
                        Label("Add photo", systemImage: "camera.viewfinder")
                            .font(.system(size: 14, weight: .semibold))
                    }
                    .buttonStyle(.bordered)
                    .tint(DesignTokens.Palette.deep)
                    .accessibilityIdentifier("segmentDetail.add-photo")

                    ForEach(segment.potholes) { pothole in
                        potholeRow(pothole)
                    }
                }
            }
        }
    }

    private func potholeRow(_ pothole: SegmentPothole) -> some View {
        VStack(alignment: .leading, spacing: DesignTokens.Space.sm) {
            HStack(alignment: .top, spacing: DesignTokens.Space.sm) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(pothole.status.displayPotholeLabel)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(DesignTokens.Palette.ink)
                    Text(
                        "\(pothole.confirmationCount) confirmations · \(pothole.uniqueReporters) reporters · updated \(relativeLabel(for: pothole.lastConfirmedAt))"
                    )
                    .font(.system(size: 12))
                    .foregroundStyle(DesignTokens.Palette.inkMuted)
                    .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: DesignTokens.Space.sm)

                Text(pothole.status.uppercased())
                    .font(.system(size: 10, weight: .bold))
                    .tracking(1.2)
                    .foregroundStyle(pothole.statusTint)
                    .padding(.horizontal, DesignTokens.Space.xs)
                    .padding(.vertical, 5)
                    .background(pothole.statusTint.opacity(0.1), in: Capsule())
            }

            HStack(spacing: DesignTokens.Space.sm) {
                Button("Still there") {
                    handlePotholeAction(.confirmPresent, pothole: pothole)
                }
                .buttonStyle(.borderedProminent)
                .tint(DesignTokens.Palette.signal)
                .accessibilityIdentifier("segmentDetail.pothole-still-there.\(pothole.id.uuidString)")

                Button("Looks fixed") {
                    handlePotholeAction(.confirmFixed, pothole: pothole)
                }
                .buttonStyle(.bordered)
                .tint(DesignTokens.Palette.success)
                .accessibilityIdentifier("segmentDetail.pothole-looks-fixed.\(pothole.id.uuidString)")
            }
        }
        .padding(DesignTokens.Space.md)
        .background(
            RoundedRectangle(cornerRadius: DesignTokens.Radius.sm, style: .continuous)
                .fill(DesignTokens.Palette.canvasSunken)
        )
    }

    private func handlePotholeAction(_ actionType: PotholeActionType, pothole: SegmentPothole) {
        let result = onSubmitPotholeAction(pothole, actionType)
        let feedback: FollowUpFeedback

        switch result {
        case .queued:
            feedback = FollowUpFeedback(
                title: "Thanks for the update",
                message: actionType == .confirmFixed
                    ? "Your “looks fixed” report will upload automatically in the background."
                    : "Your confirmation will upload automatically in the background.",
                tint: DesignTokens.Palette.signal,
                iconName: "checkmark.circle.fill"
            )
        case .unavailableLocation:
            feedback = FollowUpFeedback(
                title: "Need a fresh GPS fix",
                message: "Keep the app open for a moment, then try again near the pothole.",
                tint: DesignTokens.Palette.warning,
                iconName: "location.slash.fill"
            )
        case .insidePrivacyZone:
            feedback = FollowUpFeedback(
                title: "Inside a privacy zone",
                message: "RoadSense will not send pothole updates from an excluded area.",
                tint: DesignTokens.Palette.warning,
                iconName: "hand.raised.fill"
            )
        }

        withAnimation(DesignTokens.Motion.enter) {
            followUpFeedback = feedback
        }
    }

    private func relativeLabel(for date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: date, relativeTo: .now)
    }

    private func followUpFeedbackBanner(_ feedback: FollowUpFeedback) -> some View {
        HStack(alignment: .top, spacing: DesignTokens.Space.sm) {
            Image(systemName: feedback.iconName)
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(feedback.tint)

            VStack(alignment: .leading, spacing: 2) {
                Text(feedback.title)
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(DesignTokens.Palette.surface)
                Text(feedback.message)
                    .font(.caption)
                    .foregroundStyle(DesignTokens.Palette.surface.opacity(0.9))
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: DesignTokens.Space.sm)
        }
        .padding(DesignTokens.Space.md)
        .background(
            RoundedRectangle(cornerRadius: DesignTokens.Radius.md, style: .continuous)
                .fill(DesignTokens.Palette.deep)
        )
        .overlay(
            RoundedRectangle(cornerRadius: DesignTokens.Radius.md, style: .continuous)
                .strokeBorder(.white.opacity(0.1), lineWidth: 1)
        )
    }

    private func trustRow(label: String, value: String, valueTint: Color = DesignTokens.Palette.ink) -> some View {
        HStack {
            Text(label)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(DesignTokens.Palette.ink)
            Spacer()
            Text(value)
                .font(.system(size: 15, weight: .semibold, design: .rounded).monospacedDigit())
                .foregroundStyle(valueTint)
        }
    }

    // MARK: - Metadata card

    private var metadataCard: some View {
        sectionCard(title: "Road details") {
            VStack(alignment: .leading, spacing: DesignTokens.Space.sm) {
                metadataRow(label: "Surface", value: segment.surfaceType.capitalized)
                Divider().overlay(DesignTokens.Palette.border)
                metadataRow(label: "Length", value: "\(segment.lengthM.formatted(.number.precision(.fractionLength(0)))) m")
                Divider().overlay(DesignTokens.Palette.border)
                metadataRow(label: "Speed bump", value: segment.hasSpeedBump ? "Yes" : "No")
                Divider().overlay(DesignTokens.Palette.border)
                metadataRow(label: "Rail crossing", value: segment.hasRailCrossing ? "Yes" : "No")
                Divider().overlay(DesignTokens.Palette.border)
                metadataRow(label: "Last reading", value: lastReadingLabel)
            }
        }
    }

    private func metadataRow(label: String, value: String) -> some View {
        HStack {
            Text(label)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(DesignTokens.Palette.inkMuted)
            Spacer()
            Text(value)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(DesignTokens.Palette.ink)
        }
    }

    // MARK: - Shared building blocks

    @ViewBuilder
    private func sectionCard<Content: View>(title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: DesignTokens.Space.md) {
            Text(title.uppercased())
                .font(.system(size: 11, weight: .bold))
                .tracking(1.3)
                .foregroundStyle(DesignTokens.Palette.inkMuted)

            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(DesignTokens.Space.lg)
        .background(
            RoundedRectangle(cornerRadius: DesignTokens.Radius.md, style: .continuous)
                .fill(DesignTokens.Palette.surface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: DesignTokens.Radius.md, style: .continuous)
                .strokeBorder(DesignTokens.Palette.border, lineWidth: 1)
        )
    }

    // MARK: - Derived labels

    private var categoryCopy: String {
        let ramp = segment.aggregate.category.displayLabel
        return "\(ramp) · \(segment.aggregate.confidence.displayConfidenceLabel.lowercased())"
    }

    private var trendTint: Color {
        switch segment.aggregate.trend {
        case "improving": return DesignTokens.Palette.success
        case "worsening": return DesignTokens.Palette.warning
        default: return DesignTokens.Palette.inkMuted
        }
    }

    private var updatedLabel: String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: segment.aggregate.updatedAt, relativeTo: .now)
    }

    private var lastReadingLabel: String {
        guard let lastReadingAt = segment.aggregate.lastReadingAt else {
            return "No recent reading"
        }
        return lastReadingAt.formatted(date: .abbreviated, time: .shortened)
    }
}

private extension String {
    var displayLabel: String {
        switch self {
        case "very_rough":
            return "Very rough"
        default:
            return replacingOccurrences(of: "_", with: " ").capitalized
        }
    }

    var displayConfidenceLabel: String {
        replacingOccurrences(of: "_", with: " ").capitalized
    }

    var displayConfidenceExplanation: String {
        switch self {
        case "high":
            return "High confidence: many drivers have independently confirmed this stretch."
        case "medium":
            return "Medium confidence: enough contributions to trust the signal."
        case "low":
            return "Low confidence: early signal only. Treat with caution until more data arrives."
        default:
            return "Confidence improves as more community data arrives."
        }
    }

    var displayTrendLabel: String {
        switch self {
        case "improving":
            return "Improving"
        case "worsening":
            return "Worsening"
        default:
            return "Stable"
        }
    }

    var displayPotholeLabel: String {
        switch self {
        case "resolved":
            return "Recently marked fixed"
        default:
            return "Active pothole marker"
        }
    }
}

private extension SegmentPothole {
    var statusTint: Color {
        switch status {
        case "resolved":
            return DesignTokens.Palette.success
        default:
            return DesignTokens.Palette.warning
        }
    }
}

private struct FollowUpFeedback: Identifiable {
    let id = UUID()
    let title: String
    let message: String
    let tint: Color
    let iconName: String
    let dismissDelay: Duration = .seconds(3)
}

#Preview("Segment Detail") {
    NavigationStack {
        SegmentDetailSheet(segment: .previewSample)
    }
}

private extension SegmentDetailResponse {
    static let previewSample = SegmentDetailResponse(
        id: UUID(uuidString: "c8a1b2d3-1111-2222-3333-444444444444")!,
        roadName: "Barrington Street",
        roadType: "primary",
        municipality: "Halifax",
        lengthM: 49,
        hasSpeedBump: false,
        hasRailCrossing: false,
        surfaceType: "asphalt",
        aggregate: SegmentAggregate(
            avgRoughnessScore: 0.72,
            category: "rough",
            confidence: "high",
            totalReadings: 137,
            uniqueContributors: 34,
            potholeCount: 2,
            trend: "worsening",
            scoreLast30D: 0.78,
            score30To60D: 0.69,
            lastReadingAt: Date(timeIntervalSince1970: 1_776_000_000),
            updatedAt: Date(timeIntervalSince1970: 1_776_003_600)
        ),
        potholes: [
            SegmentPothole(
                id: UUID(uuidString: "a8f6e5c4-9999-8888-7777-666666666666")!,
                status: "active",
                latitude: 44.64882,
                longitude: -63.57512,
                confirmationCount: 3,
                uniqueReporters: 2,
                lastConfirmedAt: Date(timeIntervalSince1970: 1_776_002_400)
            )
        ],
        history: [],
        neighbors: nil
    )
}
