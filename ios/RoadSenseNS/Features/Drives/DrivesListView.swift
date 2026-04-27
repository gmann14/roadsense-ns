import SwiftUI

struct DrivesListView: View {
    let readingStore: ReadingStore

    @Environment(\.dismiss) private var dismiss
    @State private var sections: [DriveListSection] = []
    @State private var loadError: String?
    @State private var deleteCandidate: DriveSummary?
    @State private var deleteError: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DesignTokens.Space.xl) {
                if let loadError {
                    Text(loadError)
                        .font(.system(size: 14))
                        .foregroundStyle(DesignTokens.Palette.danger)
                        .accessibilityIdentifier("drives.load-error")
                }

                if sections.isEmpty && loadError == nil {
                    emptyState
                } else {
                    ForEach(sections) { section in
                        sectionView(section)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, DesignTokens.Space.xl)
            .padding(.top, DesignTokens.Space.lg)
            .padding(.bottom, DesignTokens.Space.xxxl)
        }
        .background(backgroundGradient.ignoresSafeArea())
        .navigationTitle("Recent drives")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Done") { dismiss() }
                    .accessibilityIdentifier("drives.close")
            }
        }
        .task { reload() }
        .confirmationDialog(
            "Delete this drive?",
            isPresented: Binding(
                get: { deleteCandidate != nil },
                set: { if !$0 { deleteCandidate = nil } }
            ),
            titleVisibility: .visible,
            presenting: deleteCandidate
        ) { drive in
            Button("Delete drive", role: .destructive) {
                handleDelete(drive)
            }
            Button("Cancel", role: .cancel) {
                deleteCandidate = nil
            }
        } message: { _ in
            Text("Removes the drive from this device. Already uploaded data stays public — RoadSense doesn't track who sent it.")
        }
        .alert("Couldn't delete drive", isPresented: Binding(
            get: { deleteError != nil },
            set: { if !$0 { deleteError = nil } }
        )) {
            Button("OK", role: .cancel) { deleteError = nil }
        } message: {
            Text(deleteError ?? "")
        }
    }

    private var backgroundGradient: some View {
        LinearGradient(
            colors: [DesignTokens.Palette.canvas, DesignTokens.Palette.canvasSunken],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Space.sm) {
            Text("No drives yet.")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(DesignTokens.Palette.ink)
            Text("Once you start driving, completed trips will show up here. Each one lists how much was kept on-device, how much was filtered by your privacy zones, and how much made it to the public map.")
                .font(.system(size: 14))
                .foregroundStyle(DesignTokens.Palette.inkMuted)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(DesignTokens.Space.lg)
        .background(DesignTokens.Palette.surface, in: RoundedRectangle(cornerRadius: DesignTokens.Radius.md, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: DesignTokens.Radius.md, style: .continuous)
                .strokeBorder(DesignTokens.Palette.border, lineWidth: 1)
        )
    }

    private func sectionView(_ section: DriveListSection) -> some View {
        VStack(alignment: .leading, spacing: DesignTokens.Space.sm) {
            Text(section.bucket.displayName)
                .font(.system(size: 13, weight: .bold))
                .tracking(1.2)
                .textCase(.uppercase)
                .foregroundStyle(DesignTokens.Palette.inkMuted)

            VStack(spacing: DesignTokens.Space.sm) {
                ForEach(section.drives) { drive in
                    driveRow(drive)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func driveRow(_ drive: DriveSummary) -> some View {
        VStack(alignment: .leading, spacing: DesignTokens.Space.sm) {
            HStack(alignment: .firstTextBaseline) {
                Text(timeRangeLabel(drive))
                    .font(.system(size: 17, weight: .semibold, design: .rounded))
                    .foregroundStyle(DesignTokens.Palette.ink)
                    .accessibilityIdentifier("drives.row.time")
                Spacer()
                Text(distanceLabel(drive))
                    .font(.system(size: 15, weight: .semibold).monospacedDigit())
                    .foregroundStyle(DesignTokens.Palette.ink)
                    .accessibilityIdentifier("drives.row.distance")
            }

            if drive.hasOnlyPrivacyFilteredData {
                Text("Inside a privacy zone — nothing left this device.")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(DesignTokens.Palette.smooth)
                    .accessibilityIdentifier("drives.row.privacy-zone")
            } else {
                HStack(spacing: DesignTokens.Space.lg) {
                    statChip(label: "Road data", value: "\(drive.acceptedReadingCount)")
                    if drive.privacyFilteredReadingCount > 0 {
                        statChip(
                            label: "Privacy-filtered",
                            value: "\(drive.privacyFilteredReadingCount)",
                            tint: DesignTokens.Palette.smooth
                        )
                    }
                    if drive.potholeCount > 0 {
                        statChip(
                            label: drive.potholeCount == 1 ? "Pothole" : "Potholes",
                            value: "\(drive.potholeCount)",
                            tint: DesignTokens.Palette.warning
                        )
                    }
                }
            }

            HStack {
                Spacer()
                Button(role: .destructive) {
                    deleteCandidate = drive
                } label: {
                    Text("Delete drive")
                        .font(.system(size: 13, weight: .semibold))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .tint(DesignTokens.Palette.danger)
                .accessibilityIdentifier("drives.row.delete")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(DesignTokens.Space.md)
        .background(DesignTokens.Palette.surface, in: RoundedRectangle(cornerRadius: DesignTokens.Radius.md, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: DesignTokens.Radius.md, style: .continuous)
                .strokeBorder(DesignTokens.Palette.border, lineWidth: 1)
        )
    }

    private func statChip(
        label: String,
        value: String,
        tint: Color = DesignTokens.Palette.deep
    ) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label.uppercased())
                .font(.system(size: 10, weight: .bold))
                .tracking(1.0)
                .foregroundStyle(DesignTokens.Palette.inkMuted)
            Text(value)
                .font(.system(size: 15, weight: .semibold, design: .rounded).monospacedDigit())
                .foregroundStyle(tint)
        }
    }

    private func timeRangeLabel(_ drive: DriveSummary) -> String {
        let start = drive.startedAt.formatted(date: .omitted, time: .shortened)
        if let endedAt = drive.endedAt {
            let end = endedAt.formatted(date: .omitted, time: .shortened)
            return "\(start) – \(end)"
        }
        return start
    }

    private func distanceLabel(_ drive: DriveSummary) -> String {
        if drive.distanceKm <= 0 {
            return "—"
        }
        if drive.distanceKm < 1 {
            return "\(Int(drive.distanceKm * 1_000)) m"
        }
        return "\(drive.distanceKm.formatted(.number.precision(.fractionLength(1)))) km"
    }

    private func reload() {
        do {
            let summaries = try readingStore.recentDriveSummaries()
            sections = DriveListGrouper.group(summaries, now: Date())
            loadError = nil
        } catch {
            loadError = error.localizedDescription
            sections = []
        }
    }

    private func handleDelete(_ drive: DriveSummary) {
        do {
            try readingStore.deleteDriveSession(id: drive.id)
            deleteCandidate = nil
            reload()
        } catch {
            deleteError = error.localizedDescription
            deleteCandidate = nil
        }
    }
}
