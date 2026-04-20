import Foundation
import Testing

@testable import RoadSenseNSBootstrap

struct HarnessTests {
    private let decoder = JSONDecoder()

    @Test
    func parsesFixtureAndRejectsNonMonotonicTimestamps() throws {
        let valid = """
        timestamp,type,value1,value2,value3,value4,value5
        2026-04-10T10:00:00.000Z,activity,automotive,,,,
        2026-04-10T10:00:00.020Z,gravity,0,0,1,,
        2026-04-10T10:00:01.000Z,gps,44.6488,-63.5752,54,90,5
        """

        let fixture = try SensorFixtureParser.parse(csv: valid)
        #expect(fixture.events.count == 3)

        let invalid = """
        timestamp,type,value1,value2,value3,value4,value5
        2026-04-10T10:00:01.000Z,activity,automotive,,,,
        2026-04-10T10:00:01.000Z,gps,44.6488,-63.5752,54,90,5
        """

        do {
            _ = try SensorFixtureParser.parse(csv: invalid)
            Issue.record("Expected non-monotonic fixture parse failure")
        } catch let error as SensorFixtureParseError {
            #expect(error == .nonMonotonicTimestamp(line: 3))
        }
    }

    @Test
    func replaysAllFixturesAndMatchesExpectedEnvelopes() throws {
        let resourceURL = try #require(Bundle.module.resourceURL)
        let expectedFiles = try FileManager.default.contentsOfDirectory(
            at: resourceURL,
            includingPropertiesForKeys: nil
        )
            .filter { $0.lastPathComponent.hasSuffix(".expected.json") }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }

        #expect(expectedFiles.isEmpty == false)

        for expectedURL in expectedFiles {
            let expected = try decoder.decode(SensorFixtureExpected.self, from: Data(contentsOf: expectedURL))
            let fixtureURL = try #require(Bundle.module.url(forResource: expected.fixture.replacingOccurrences(of: ".csv", with: ""), withExtension: "csv"))
            let csv = try String(contentsOf: fixtureURL, encoding: .utf8)
            let fixture = try SensorFixtureParser.parse(csv: csv)
            let privacyZones = expected.privacyZone.map {
                [
                    PrivacyZone(
                        latitude: $0.latitude,
                        longitude: $0.longitude,
                        radiusMeters: $0.radiusMeters
                    )
                ]
            } ?? []
            let result = SensorFixtureRunner.replay(
                fixture: fixture,
                privacyZones: privacyZones
            )

            #expect(result.emittedReadings.count == expected.expectedWindows)
            #expect(result.emittedReadings.contains { $0.isPothole } == expected.expectedPotholeFlagged)
            if let expectedPrivacyFilteredCount = expected.expectedPrivacyFilteredCount {
                #expect(result.privacyFilteredCount == expectedPrivacyFilteredCount)
            }
            if let expectedRejectedCount = expected.expectedRejectedCount {
                #expect(result.rejectedCount == expectedRejectedCount)
            }

            if let expectedRmsRange = expected.expectedRmsRange {
                let rms = try #require(result.emittedReadings.first?.roughnessRMS)
                #expect(rms >= expectedRmsRange[0])
                #expect(rms <= expectedRmsRange[1])
            } else {
                #expect(result.emittedReadings.isEmpty)
            }

            if let expectedMaxSpikeGRange = expected.expectedMaxSpikeGRange {
                let maxSpike = result.maxPotholeMagnitudeG ?? 0
                #expect(maxSpike >= expectedMaxSpikeGRange[0])
                #expect(maxSpike <= expectedMaxSpikeGRange[1])
            } else {
                #expect(result.maxPotholeMagnitudeG == nil)
            }
        }
    }
}
