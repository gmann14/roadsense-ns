import SwiftUI

struct StatsView: View {
    let statsStore: UserStatsStore

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
                LabeledContent("Kilometres mapped", value: summary.totalKmRecorded.formatted(.number.precision(.fractionLength(1))))
                LabeledContent("Accepted readings", value: "\(summary.acceptedReadingCount)")
                LabeledContent("Pending uploads", value: "\(summary.pendingUploadCount)")
                LabeledContent("Privacy-filtered", value: "\(summary.privacyFilteredCount)")
            }

            Section("What it affected") {
                LabeledContent("Segments contributed", value: "\(summary.totalSegmentsContributed)")
                LabeledContent("Potholes flagged", value: "\(summary.potholesReported)")

                if let lastDriveAt = summary.lastDriveAt {
                    LabeledContent("Last drive", value: lastDriveAt.formatted(date: .abbreviated, time: .shortened))
                } else {
                    LabeledContent("Last drive", value: "No drives yet")
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
        .task {
            loadSummary()
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
