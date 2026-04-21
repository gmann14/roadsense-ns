import SwiftUI

struct SimHarnessView: View {
    @State private var selectedFixtureID = HarnessFixtureCatalog.fixtures.first?.id
    @State private var lastResult: SensorFixtureReplayResult?
    @State private var loadedFixture: LoadedHarnessFixture?
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            List {
                Section("Fixtures") {
                    Picker("Fixture", selection: selectedFixtureBinding) {
                        ForEach(HarnessFixtureCatalog.fixtures) { fixture in
                            Text(fixture.title).tag(Optional(fixture.id))
                        }
                    }
                    .pickerStyle(.navigationLink)

                    if let loadedFixture {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(loadedFixture.definition.summary)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                            Text("Expected windows: \(loadedFixture.expected.expectedWindows)")
                            Text("Expected pothole: \(loadedFixture.expected.expectedPotholeFlagged ? "yes" : "no")")
                            if let rmsRange = loadedFixture.expected.expectedRmsRange,
                               rmsRange.count >= 2 {
                                Text(
                                    String(
                                        format: "Expected RMS range: %.2f - %.2f",
                                        rmsRange[0],
                                        rmsRange[1]
                                    )
                                )
                            }
                            if let spikeRange = loadedFixture.expected.expectedMaxSpikeGRange,
                               spikeRange.count >= 2 {
                                Text(
                                    String(
                                        format: "Expected max spike: %.2f - %.2f g",
                                        spikeRange[0],
                                        spikeRange[1]
                                    )
                                )
                            }
                        }
                    }

                    Button("Replay Fixture") {
                        replaySelectedFixture()
                    }
                    .disabled(loadedFixture == nil)
                }

                Section("Replay Result") {
                    if let result = lastResult {
                        Text("Accepted windows: \(result.emittedReadings.count)")
                        Text("Privacy-filtered windows: \(result.privacyFilteredCount)")
                        Text("Rejected windows: \(result.rejectedCount)")
                        Text("Pothole flagged: \(result.emittedReadings.contains(where: \.isPothole) ? "yes" : "no")")

                        if let first = result.emittedReadings.first {
                            Text(String(format: "RMS roughness: %.3f", first.roughnessRMS))
                            if let magnitude = first.potholeMagnitudeG {
                                Text(String(format: "First pothole magnitude: %.3f g", magnitude))
                            }
                        }

                        if let maxMagnitude = result.maxPotholeMagnitudeG {
                            Text(String(format: "Max pothole magnitude: %.3f g", maxMagnitude))
                        }
                    } else {
                        Text("No replay has been run yet.")
                            .foregroundStyle(.secondary)
                    }
                }

                if let errorMessage {
                    Section("Error") {
                        Text(errorMessage)
                            .foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle("Sim Harness")
            .onAppear {
                loadSelectedFixture()
            }
            .onChange(of: selectedFixtureID) { _, _ in
                loadSelectedFixture()
            }
        }
    }

    private var selectedFixtureBinding: Binding<String?> {
        Binding(
            get: { selectedFixtureID },
            set: { selectedFixtureID = $0 }
        )
    }

    private func loadSelectedFixture() {
        errorMessage = nil
        lastResult = nil

        guard let definition = HarnessFixtureCatalog.fixtures.first(where: { $0.id == selectedFixtureID }) else {
            loadedFixture = nil
            return
        }

        do {
            loadedFixture = try HarnessFixtureCatalog.load(definition)
        } catch {
            loadedFixture = nil
            errorMessage = error.localizedDescription
        }
    }

    private func replaySelectedFixture() {
        errorMessage = nil

        guard let loadedFixture else {
            errorMessage = "Fixture is not loaded."
            return
        }

        let privacyZones = loadedFixture.expected.privacyZone.map {
            [
                PrivacyZone(
                    latitude: $0.latitude,
                    longitude: $0.longitude,
                    radiusMeters: $0.radiusMeters
                )
            ]
        } ?? []

        lastResult = SensorFixtureRunner.replay(
            fixture: loadedFixture.fixture,
            privacyZones: privacyZones
        )
    }
}
