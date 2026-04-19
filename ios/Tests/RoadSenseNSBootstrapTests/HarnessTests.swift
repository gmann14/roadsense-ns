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
    func replaysFixtureAndMatchesExpectedEnvelope() throws {
        let fixtureData = try #require(Bundle.module.url(forResource: "pothole-hit", withExtension: "csv"))
        let expectedData = try #require(Bundle.module.url(forResource: "pothole-hit.expected", withExtension: "json"))

        let csv = try String(contentsOf: fixtureData, encoding: .utf8)
        let expected = try decoder.decode(SensorFixtureExpected.self, from: Data(contentsOf: expectedData))
        let fixture = try SensorFixtureParser.parse(csv: csv)
        let result = SensorFixtureRunner.replay(fixture: fixture)

        #expect(result.emittedReadings.count == expected.expectedWindows)
        #expect(result.emittedReadings.contains { $0.isPothole } == expected.expectedPotholeFlagged)

        let rms = try #require(result.emittedReadings.first?.roughnessRMS)
        #expect(rms >= expected.expectedRmsRange[0])
        #expect(rms <= expected.expectedRmsRange[1])

        let maxSpike = try #require(result.maxPotholeMagnitudeG)
        #expect(maxSpike >= expected.expectedMaxSpikeGRange[0])
        #expect(maxSpike <= expected.expectedMaxSpikeGRange[1])
    }
}
