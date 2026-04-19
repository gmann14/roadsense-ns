import Foundation
import Testing

@testable import RoadSenseNSBootstrap

@Suite("Reading builder")
struct ReadingBuilderTests {
    @Test("emits a window once cumulative travel reaches 40 meters")
    func emitsWindowAtFortyMeters() {
        var builder = ReadingBuilder()

        for second in 0..<40 {
            builder.addMotionSample(
                MotionSample(
                    timestamp: TimeInterval(second),
                    userAcceleration: MotionVector3(x: 0, y: 0, z: 1),
                    gravity: MotionVector3(x: 0, y: 0, z: 1)
                )
            )
        }

        #expect(builder.addLocationSample(sample(atMeters: 0, second: 0)) == nil)
        #expect(builder.addLocationSample(sample(atMeters: 20, second: 5)) == nil)

        guard let reading = builder.addLocationSample(sample(atMeters: 40, second: 10)) else {
            Issue.record("Expected an emitted reading window")
            return
        }

        #expect(reading.sampleCount == 40)
        #expect(reading.durationSeconds == 10)
        #expect(reading.roughnessRMS == 1)
        #expect(reading.latitude.isApproximately(equalTo: metersToLatitude(20), tolerance: 0.000001))
        #expect(reading.gpsAccuracyMeters == 5)
    }

    @Test("drops window when any gps sample exceeds 20 meters accuracy")
    func dropsWindowForPoorAccuracy() {
        var builder = ReadingBuilder()

        for second in 0..<40 {
            builder.addMotionSample(
                MotionSample(
                    timestamp: TimeInterval(second),
                    userAcceleration: MotionVector3(x: 0, y: 0, z: 0.5),
                    gravity: MotionVector3(x: 0, y: 0, z: 1)
                )
            )
        }

        #expect(builder.addLocationSample(sample(atMeters: 0, second: 0)) == nil)
        #expect(builder.addLocationSample(sample(atMeters: 10, second: 3, horizontalAccuracy: 25)) == nil)
        #expect(builder.addLocationSample(sample(atMeters: 50, second: 8)) == nil)
    }

    @Test("drops window when duration exceeds 15 seconds")
    func dropsWindowWhenDurationTooLong() {
        var builder = ReadingBuilder()

        for second in 0..<40 {
            builder.addMotionSample(
                MotionSample(
                    timestamp: TimeInterval(second),
                    userAcceleration: MotionVector3(x: 0, y: 0, z: 0.5),
                    gravity: MotionVector3(x: 0, y: 0, z: 1)
                )
            )
        }

        #expect(builder.addLocationSample(sample(atMeters: 0, second: 0)) == nil)
        #expect(builder.addLocationSample(sample(atMeters: 20, second: 8)) == nil)
        #expect(builder.addLocationSample(sample(atMeters: 40, second: 16)) == nil)
    }

    @Test("drops window when heading variance exceeds 60 degrees")
    func dropsWindowWhenHeadingVarianceTooHigh() {
        var builder = ReadingBuilder()

        for second in 0..<40 {
            builder.addMotionSample(
                MotionSample(
                    timestamp: TimeInterval(second),
                    userAcceleration: MotionVector3(x: 0, y: 0, z: 0.5),
                    gravity: MotionVector3(x: 0, y: 0, z: 1)
                )
            )
        }

        #expect(builder.addLocationSample(sample(atMeters: 0, second: 0, headingDegrees: 0)) == nil)
        #expect(builder.addLocationSample(sample(atMeters: 20, second: 4, headingDegrees: 10)) == nil)
        #expect(builder.addLocationSample(sample(atMeters: 40, second: 8, headingDegrees: 120)) == nil)
    }

    @Test("drops window with fewer than 30 motion samples")
    func dropsWindowWhenSampleCountTooLow() {
        var builder = ReadingBuilder()

        for second in 0..<20 {
            builder.addMotionSample(
                MotionSample(
                    timestamp: TimeInterval(second),
                    userAcceleration: MotionVector3(x: 0, y: 0, z: 0.5),
                    gravity: MotionVector3(x: 0, y: 0, z: 1)
                )
            )
        }

        #expect(builder.addLocationSample(sample(atMeters: 0, second: 0)) == nil)
        #expect(builder.addLocationSample(sample(atMeters: 20, second: 3)) == nil)
        #expect(builder.addLocationSample(sample(atMeters: 40, second: 6)) == nil)
    }

    private func sample(
        atMeters meters: Double,
        second: TimeInterval,
        speedKmh: Double = 45,
        headingDegrees: Double = 0,
        horizontalAccuracy: Double = 5
    ) -> LocationSample {
        LocationSample(
            timestamp: second,
            latitude: metersToLatitude(meters),
            longitude: 0,
            horizontalAccuracyMeters: horizontalAccuracy,
            speedKmh: speedKmh,
            headingDegrees: headingDegrees
        )
    }

    private func metersToLatitude(_ meters: Double) -> Double {
        meters * 180.0 / (.pi * 6_371_000.0)
    }
}

private extension Double {
    func isApproximately(equalTo other: Double, tolerance: Double) -> Bool {
        abs(self - other) <= tolerance
    }
}
