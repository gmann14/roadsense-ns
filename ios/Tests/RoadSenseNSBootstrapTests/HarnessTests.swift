import Foundation
import Testing

@testable import RoadSenseNSBootstrap

struct HarnessTests {
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
        let csv = """
        timestamp,type,value1,value2,value3,value4,value5
        2026-04-10T10:00:00.000Z,activity,automotive,,,,
        2026-04-10T10:00:00.020Z,gravity,0,0,1,,
        2026-04-10T10:00:01.000Z,gps,44.648800,-63.575200,54,90,5
        2026-04-10T10:00:01.020Z,accel,0.00,0.00,-0.80,,
        2026-04-10T10:00:01.040Z,accel,0.00,0.00,2.80,,
        2026-04-10T10:00:01.060Z,accel,0.00,0.00,0.40,,
        2026-04-10T10:00:01.080Z,accel,0.00,0.00,0.50,,
        2026-04-10T10:00:01.100Z,accel,0.00,0.00,0.60,,
        2026-04-10T10:00:01.120Z,accel,0.00,0.00,0.70,,
        2026-04-10T10:00:01.140Z,accel,0.00,0.00,0.80,,
        2026-04-10T10:00:01.160Z,accel,0.00,0.00,0.90,,
        2026-04-10T10:00:01.180Z,accel,0.00,0.00,1.00,,
        2026-04-10T10:00:01.200Z,accel,0.00,0.00,1.10,,
        2026-04-10T10:00:01.220Z,accel,0.00,0.00,1.20,,
        2026-04-10T10:00:01.240Z,accel,0.00,0.00,1.30,,
        2026-04-10T10:00:01.260Z,accel,0.00,0.00,1.40,,
        2026-04-10T10:00:01.280Z,accel,0.00,0.00,1.50,,
        2026-04-10T10:00:01.300Z,accel,0.00,0.00,1.60,,
        2026-04-10T10:00:01.320Z,accel,0.00,0.00,1.70,,
        2026-04-10T10:00:01.340Z,accel,0.00,0.00,1.80,,
        2026-04-10T10:00:01.360Z,accel,0.00,0.00,1.90,,
        2026-04-10T10:00:01.380Z,accel,0.00,0.00,2.00,,
        2026-04-10T10:00:01.400Z,accel,0.00,0.00,2.10,,
        2026-04-10T10:00:01.420Z,accel,0.00,0.00,2.20,,
        2026-04-10T10:00:01.440Z,accel,0.00,0.00,2.30,,
        2026-04-10T10:00:01.460Z,accel,0.00,0.00,2.40,,
        2026-04-10T10:00:01.480Z,accel,0.00,0.00,2.50,,
        2026-04-10T10:00:01.500Z,accel,0.00,0.00,2.60,,
        2026-04-10T10:00:01.520Z,accel,0.00,0.00,2.70,,
        2026-04-10T10:00:01.540Z,accel,0.00,0.00,2.80,,
        2026-04-10T10:00:01.560Z,accel,0.00,0.00,2.90,,
        2026-04-10T10:00:01.580Z,accel,0.00,0.00,3.00,,
        2026-04-10T10:00:01.600Z,accel,0.00,0.00,3.10,,
        2026-04-10T10:00:01.620Z,accel,0.00,0.00,3.20,,
        2026-04-10T10:00:01.640Z,accel,0.00,0.00,3.30,,
        2026-04-10T10:00:01.660Z,accel,0.00,0.00,3.40,,
        2026-04-10T10:00:01.680Z,accel,0.00,0.00,3.50,,
        2026-04-10T10:00:01.700Z,accel,0.00,0.00,3.60,,
        2026-04-10T10:00:01.720Z,accel,0.00,0.00,3.70,,
        2026-04-10T10:00:01.740Z,accel,0.00,0.00,3.80,,
        2026-04-10T10:00:01.760Z,accel,0.00,0.00,3.90,,
        2026-04-10T10:00:01.780Z,accel,0.00,0.00,4.00,,
        2026-04-10T10:00:01.800Z,accel,0.00,0.00,4.10,,
        2026-04-10T10:00:01.820Z,accel,0.00,0.00,4.20,,
        2026-04-10T10:00:01.840Z,accel,0.00,0.00,4.30,,
        2026-04-10T10:00:01.860Z,accel,0.00,0.00,4.40,,
        2026-04-10T10:00:01.880Z,accel,0.00,0.00,4.50,,
        2026-04-10T10:00:01.900Z,accel,0.00,0.00,4.60,,
        2026-04-10T10:00:01.920Z,accel,0.00,0.00,4.70,,
        2026-04-10T10:00:01.940Z,accel,0.00,0.00,4.80,,
        2026-04-10T10:00:01.960Z,accel,0.00,0.00,4.90,,
        2026-04-10T10:00:01.980Z,accel,0.00,0.00,5.00,,
        2026-04-10T10:00:02.000Z,accel,0.00,0.00,5.10,,
        2026-04-10T10:00:02.020Z,accel,0.00,0.00,5.20,,
        2026-04-10T10:00:02.040Z,accel,0.00,0.00,5.30,,
        2026-04-10T10:00:02.060Z,accel,0.00,0.00,5.40,,
        2026-04-10T10:00:02.080Z,accel,0.00,0.00,5.50,,
        2026-04-10T10:00:02.100Z,accel,0.00,0.00,5.60,,
        2026-04-10T10:00:02.120Z,accel,0.00,0.00,5.70,,
        2026-04-10T10:00:02.140Z,accel,0.00,0.00,5.80,,
        2026-04-10T10:00:02.160Z,accel,0.00,0.00,5.90,,
        2026-04-10T10:00:02.180Z,accel,0.00,0.00,6.00,,
        2026-04-10T10:00:02.200Z,accel,0.00,0.00,6.10,,
        2026-04-10T10:00:02.220Z,accel,0.00,0.00,6.20,,
        2026-04-10T10:00:02.240Z,accel,0.00,0.00,6.30,,
        2026-04-10T10:00:02.260Z,accel,0.00,0.00,6.40,,
        2026-04-10T10:00:02.280Z,accel,0.00,0.00,6.50,,
        2026-04-10T10:00:02.300Z,accel,0.00,0.00,6.60,,
        2026-04-10T10:00:02.320Z,accel,0.00,0.00,6.70,,
        2026-04-10T10:00:02.340Z,accel,0.00,0.00,6.80,,
        2026-04-10T10:00:02.360Z,accel,0.00,0.00,6.90,,
        2026-04-10T10:00:02.380Z,accel,0.00,0.00,7.00,,
        2026-04-10T10:00:03.000Z,gps,44.649160,-63.575200,54,90,5
        2026-04-10T10:00:04.000Z,gps,44.649520,-63.575200,54,90,5
        """

        let expected = SensorFixtureExpected(
            fixture: "pothole-hit.csv",
            expectedWindows: 1,
            expectedPotholeFlagged: true,
            expectedRmsRange: [3.5, 5.0],
            expectedMaxSpikeGRange: [2.5, 7.5]
        )

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
