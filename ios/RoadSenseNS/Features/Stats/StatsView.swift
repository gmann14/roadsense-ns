import SwiftUI

struct StatsView: View {
    let statsStore: UserStatsStore

    @Environment(\.dismiss) private var dismiss
    @State private var summary = UserStatsSummary(
        totalKmRecorded: 0,
        totalSegmentsContributed: 0,
        lastDriveAt: nil,
        potholesReported: 0,
        acceptedReadingCount: 0,
        privacyFilteredCount: 0,
        pendingUploadCount: 0
    )
    @State private var errorMessage: String?

    var body: some View {
        List {
            Section("Your contribution") {
                statsRow(
                    title: "Kilometres mapped",
                    value: summary.totalKmRecorded.formatted(.number.precision(.fractionLength(1))),
                    accessibilityID: "stats.kilometres-mapped"
                )
                statsRow(
                    title: "Accepted readings",
                    value: "\(summary.acceptedReadingCount)",
                    accessibilityID: "stats.accepted-readings"
                )
                statsRow(
                    title: "Pending uploads",
                    value: "\(summary.pendingUploadCount)",
                    accessibilityID: "stats.pending-uploads"
                )
                statsRow(
                    title: "Privacy-filtered",
                    value: "\(summary.privacyFilteredCount)",
                    accessibilityID: "stats.privacy-filtered"
                )
            }

            Section("What it affected") {
                statsRow(
                    title: "Segments contributed",
                    value: "\(summary.totalSegmentsContributed)",
                    accessibilityID: "stats.segments-contributed"
                )
                statsRow(
                    title: "Potholes flagged",
                    value: "\(summary.potholesReported)",
                    accessibilityID: "stats.potholes-flagged"
                )

                if let lastDriveAt = summary.lastDriveAt {
                    statsRow(
                        title: "Last drive",
                        value: lastDriveAt.formatted(date: .abbreviated, time: .shortened),
                        accessibilityID: "stats.last-drive"
                    )
                } else {
                    statsRow(
                        title: "Last drive",
                        value: "No drives yet",
                        accessibilityID: "stats.last-drive"
                    )
                }
            }

            Section("How to read this") {
                Text("Accepted readings passed device-side quality filters and were stored locally for upload.")
                Text("Privacy-filtered readings never leave the device and are counted only so you can verify that your zones are working.")
            }

            if let errorMessage {
                Section {
                    Text(errorMessage)
                        .foregroundStyle(.red)
                }
            }
        }
        .navigationTitle("Stats")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Done") {
                    dismiss()
                }
                .accessibilityIdentifier("stats.close")
            }
        }
        .task {
            loadSummary()
        }
    }

    private func statsRow(title: String, value: String, accessibilityID: String) -> some View {
        LabeledContent(title) {
            Text(value)
                .accessibilityIdentifier(accessibilityID)
        }
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
