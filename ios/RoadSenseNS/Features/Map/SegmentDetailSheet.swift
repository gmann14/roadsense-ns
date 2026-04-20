import SwiftUI

struct SegmentDetailSheet: View {
    let segment: SegmentDetailResponse

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header
                primaryStats
                scorePanel
                explanationBlock
                metadataBlock
            }
            .padding(20)
        }
        .background(Color(.systemGroupedBackground))
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(segment.roadName)
                .font(.title2.weight(.semibold))

            Text(segment.municipality)
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }

    private var primaryStats: some View {
        HStack(spacing: 12) {
            statChip(title: "Category", value: segment.aggregate.category.displayLabel, tint: categoryTint)
            statChip(title: "Confidence", value: segment.aggregate.confidence.displayConfidenceLabel, tint: .blue)
            statChip(title: "Updated", value: updatedLabel, tint: .secondary)
        }
    }

    private var scorePanel: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Current score")
                .font(.headline)

            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(segment.aggregate.avgRoughnessScore.formatted(.number.precision(.fractionLength(2))))
                    .font(.system(size: 38, weight: .bold, design: .rounded))

                Text(segment.aggregate.trend.displayTrendLabel)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
            }

            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color.secondary.opacity(0.1))
                .frame(height: 92)
                .overlay(alignment: .leading) {
                    Text("Trend history is coming as more data accumulates.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 16)
                }
        }
        .padding(18)
        .background(.background, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
    }

    private var explanationBlock: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("How this score was built")
                .font(.headline)

            Text("Based on \(segment.aggregate.totalReadings) readings from \(segment.aggregate.uniqueContributors) contributors.")
            Text("\(segment.aggregate.potholeCount) pothole reports nearby.")
            Text(segment.aggregate.confidence.displayConfidenceExplanation)
        }
        .font(.subheadline)
    }

    private var metadataBlock: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Road details")
                .font(.headline)

            metadataRow(label: "Surface", value: segment.surfaceType.capitalized)
            metadataRow(label: "Length", value: "\(segment.lengthM.formatted(.number.precision(.fractionLength(0)))) m")
            metadataRow(label: "Speed bump", value: segment.hasSpeedBump ? "Yes" : "No")
            metadataRow(label: "Rail crossing", value: segment.hasRailCrossing ? "Yes" : "No")
            metadataRow(label: "Last reading", value: lastReadingLabel)
        }
        .font(.subheadline)
    }

    private var categoryTint: Color {
        DesignTokens.rampColor(for: segment.aggregate.category)
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

    private func statChip(title: String, value: String, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title.uppercased())
                .font(.caption.weight(.bold))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.primary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private func metadataRow(label: String, value: String) -> some View {
        HStack {
            Text(label)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
        }
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
            return "High confidence: many drivers have contributed data here."
        case "medium":
            return "Medium confidence: enough data is in place to trust the signal."
        case "low":
            return "Low confidence: this is still an early signal and should be treated cautiously."
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
        history: [],
        neighbors: nil
    )
}
