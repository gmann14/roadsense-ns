import SwiftUI

struct StatsView: View {
    let statsStore: UserStatsStore

    @Environment(\.dismiss) private var dismiss
    @State private var summary = UserStatsSummary.zero
    @State private var errorMessage: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DesignTokens.Space.xl) {
                hero
                contributionCard
                reachCard
                explainerCard

                if let errorMessage {
                    Text(errorMessage)
                        .font(.system(size: 14))
                        .foregroundStyle(DesignTokens.Palette.danger)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, DesignTokens.Space.xl)
            .padding(.top, DesignTokens.Space.lg)
            .padding(.bottom, DesignTokens.Space.xxxl)
        }
        .background(backgroundGradient.ignoresSafeArea())
        .navigationTitle("Stats")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Done") { dismiss() }
                    .accessibilityIdentifier("stats.close")
            }
        }
        .task { loadSummary() }
    }

    private var backgroundGradient: some View {
        LinearGradient(
            colors: [DesignTokens.Palette.canvas, DesignTokens.Palette.canvasSunken],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    private var hero: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Space.md) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: DesignTokens.Space.xs) {
                    Text("KILOMETRES RECORDED")
                        .font(.system(size: 11, weight: .bold))
                        .tracking(1.4)
                        .foregroundStyle(DesignTokens.Palette.inkMuted)
                    Text(formattedKm)
                        .font(DesignTokens.TypeStyle.numberLg)
                        .foregroundStyle(DesignTokens.Palette.ink)
                        .accessibilityIdentifier("stats.kilometres-mapped")
                    Text(lastDriveLabel)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(DesignTokens.Palette.inkMuted)
                        .accessibilityIdentifier("stats.last-drive")
                }

                Spacer(minLength: DesignTokens.Space.md)

                medallion
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

    private var medallion: some View {
        ZStack {
            Circle()
                .fill(DesignTokens.Palette.deep.opacity(0.08))
                .frame(width: 84, height: 84)
            Circle()
                .stroke(DesignTokens.Palette.deep.opacity(0.28), lineWidth: 2)
                .frame(width: 84, height: 84)
            VStack(spacing: 2) {
                Image(systemName: "road.lanes")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(DesignTokens.Palette.deep)
                Text("\(summary.totalSegmentsContributed)")
                    .font(.system(size: 16, weight: .bold, design: .rounded))
                    .foregroundStyle(DesignTokens.Palette.deep)
                    .accessibilityIdentifier("stats.segments-contributed")
            }
        }
    }

    private var contributionCard: some View {
        sectionCard(title: "Your readings") {
            statRow(
                label: "Accepted readings",
                value: "\(summary.acceptedReadingCount)",
                identifier: "stats.accepted-readings"
            )
            Divider()
            statRow(
                label: "Pending uploads",
                value: "\(summary.pendingUploadCount)",
                identifier: "stats.pending-uploads"
            )
            Divider()
            statRow(
                label: "Privacy-filtered",
                value: "\(summary.privacyFilteredCount)",
                identifier: "stats.privacy-filtered",
                valueTint: DesignTokens.Palette.smooth
            )
        }
    }

    private var reachCard: some View {
        sectionCard(title: "What it affected") {
            statRow(
                label: "Potholes flagged",
                value: "\(summary.potholesReported)",
                identifier: "stats.potholes-flagged",
                valueTint: summary.potholesReported > 0 ? DesignTokens.Palette.warning : DesignTokens.Palette.ink
            )
        }
    }

    private var explainerCard: some View {
        sectionCard(title: "How to read this") {
            VStack(alignment: .leading, spacing: DesignTokens.Space.sm) {
                Text("Accepted readings passed device-side quality filters and were stored locally first. Only the mid-drive readings that survive endpoint trimming become uploadable.")
                Text("Privacy-filtered readings never leave the device. That count exists so you can confirm your zones are working on top of the default endpoint trimming.")
            }
            .font(.system(size: 14))
            .foregroundStyle(DesignTokens.Palette.inkMuted)
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private func sectionCard<Content: View>(title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: DesignTokens.Space.md) {
            Text(title)
                .font(.system(size: 13, weight: .bold))
                .tracking(1.2)
                .foregroundStyle(DesignTokens.Palette.inkMuted)
                .textCase(.uppercase)

            VStack(alignment: .leading, spacing: DesignTokens.Space.sm) {
                content()
            }
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

    private func statRow(
        label: String,
        value: String,
        identifier: String,
        valueTint: Color = DesignTokens.Palette.ink
    ) -> some View {
        HStack {
            Text(label)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(DesignTokens.Palette.ink)
            Spacer()
            Text(value)
                .font(.system(size: 17, weight: .semibold, design: .rounded).monospacedDigit())
                .foregroundStyle(valueTint)
                .accessibilityIdentifier(identifier)
        }
    }

    private var formattedKm: String {
        summary.totalKmRecorded.formatted(.number.precision(.fractionLength(1)))
    }

    private var lastDriveLabel: String {
        if let lastDriveAt = summary.lastDriveAt {
            return "Last drive · \(lastDriveAt.formatted(date: .abbreviated, time: .shortened))"
        }
        return "No drives yet"
    }

    private func loadSummary() {
        do {
            summary = try statsStore.summary()
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
