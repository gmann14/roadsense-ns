import Foundation
import Testing

@testable import RoadSenseNSBootstrap

@Suite("Roughness scorer")
struct RoughnessScorerTests {
    @Test("preserves the RMS of a high-frequency sine wave")
    func preservesHighFrequencySine() {
        let scorer = RoughnessScorer()
        let amplitude = 1.0
        let samples = sineWave(
            frequencyHz: 5,
            amplitude: amplitude,
            sampleRateHz: 50,
            sampleCount: 2_000
        )

        let score = scorer.score(verticalAccelerations: samples)

        #expect(score >= 0.69)
        #expect(score <= 0.73)
    }

    @Test("attenuates a whole-window step transition")
    func attenuatesStepSignal() {
        let scorer = RoughnessScorer()
        let samples = Array(repeating: 0.0, count: 100) + Array(repeating: 1.0, count: 100)

        let score = scorer.score(verticalAccelerations: samples)

        #expect(score >= 0.16)
        #expect(score <= 0.18)
    }

    @Test("scores a real pothole fixture in the filtered-RMS range")
    func scoresRealFixtureClip() throws {
        let scorer = RoughnessScorer()
        let samples = try motionSamples(fromFixtureNamed: "pothole-hit")

        let score = scorer.score(samples: samples)

        #expect(score >= 0.63)
        #expect(score <= 0.68)
    }

    private func motionSamples(fromFixtureNamed name: String) throws -> [MotionSample] {
        let fixtureURL = try #require(Bundle.module.url(forResource: name, withExtension: "csv"))
        let csv = try String(contentsOf: fixtureURL, encoding: .utf8)
        let fixture = try SensorFixtureParser.parse(csv: csv)

        var gravity = MotionVector3(x: 0, y: 0, z: 1)
        var samples: [MotionSample] = []
        for event in fixture.events {
            switch event {
            case let .gravity(_, nextGravity):
                gravity = nextGravity
            case let .accel(timestamp, userAcceleration):
                samples.append(
                    MotionSample(
                        timestamp: timestamp.timeIntervalSince1970,
                        userAcceleration: userAcceleration,
                        gravity: gravity
                    )
                )
            default:
                continue
            }
        }

        return samples
    }

    private func sineWave(
        frequencyHz: Double,
        amplitude: Double,
        sampleRateHz: Double,
        sampleCount: Int
    ) -> [Double] {
        (0..<sampleCount).map { index in
            let time = Double(index) / sampleRateHz
            return sin(2 * .pi * frequencyHz * time) * amplitude
        }
    }
}
