import Foundation
import Testing

@testable import RoadSenseNSBootstrap

@Suite("Location sample validation")
struct LocationSampleValidationTests {
    @Test("rejects a fix with negative horizontal accuracy")
    func rejectsNegativeAccuracy() {
        #expect(
            LocationSample.fromCoreLocation(
                timestamp: 1,
                latitude: 44.65,
                longitude: -63.57,
                horizontalAccuracy: -1,
                speedMetersPerSecond: 10,
                courseDegrees: 90
            ) == nil
        )
    }

    @Test("rejects non-finite or out-of-range coordinates")
    func rejectsBadCoordinates() {
        #expect(LocationSample.fromCoreLocation(
            timestamp: 1, latitude: .nan, longitude: -63.57,
            horizontalAccuracy: 5, speedMetersPerSecond: 10, courseDegrees: 90
        ) == nil)
        #expect(LocationSample.fromCoreLocation(
            timestamp: 1, latitude: 95, longitude: -63.57,
            horizontalAccuracy: 5, speedMetersPerSecond: 10, courseDegrees: 90
        ) == nil)
    }

    @Test("invalid course becomes an unknown heading, not due north")
    func invalidCourseIsUnknown() throws {
        let sample = try #require(LocationSample.fromCoreLocation(
            timestamp: 1,
            latitude: 44.65,
            longitude: -63.57,
            horizontalAccuracy: 5,
            speedMetersPerSecond: -1,
            courseDegrees: -1
        ))

        #expect(sample.hasValidHeading == false)
        #expect(sample.headingDegrees == LocationSample.unknownHeading)
        #expect(sample.speedKmh == 0)
    }

    @Test("valid course and speed are preserved")
    func validCoursePreserved() throws {
        let sample = try #require(LocationSample.fromCoreLocation(
            timestamp: 1,
            latitude: 44.65,
            longitude: -63.57,
            horizontalAccuracy: 5,
            speedMetersPerSecond: 10,
            courseDegrees: 182.5
        ))

        #expect(sample.hasValidHeading)
        #expect(sample.headingDegrees == 182.5)
        #expect(sample.speedKmh == 36)
    }

    @Test("unknown-heading samples do not abort a straight window")
    func unknownHeadingSamplesDoNotPoisonVariance() throws {
        var builder = ReadingBuilder()
        for index in 0..<50 {
            builder.addMotionSample(
                MotionSample(
                    timestamp: Double(index) / 50.0,
                    userAcceleration: MotionVector3(x: 0, y: 0, z: 0.3),
                    gravity: MotionVector3(x: 0, y: 0, z: 1)
                )
            )
        }

        // Driving due south (180°) with one invalid-course fix in the middle.
        // Before the fix the invalid course read as 0° (a 180° swing) and the
        // variance gate threw the window away.
        let first = builder.addLocationSample(sample(atMeters: 0, second: 0, heading: 180))
        #expect(first == nil)
        let second = builder.addLocationSample(sample(atMeters: 20, second: 4, heading: LocationSample.unknownHeading))
        #expect(second == nil)
        let completed = builder.addLocationSample(sample(atMeters: 40, second: 8, heading: 180))
        let window = try #require(completed)

        #expect(abs(window.headingDegrees - 180) < 0.001)
    }

    @Test("window with no known heading reports unknown heading")
    func windowWithoutHeadingIsUnknown() throws {
        var builder = ReadingBuilder()
        for index in 0..<50 {
            builder.addMotionSample(
                MotionSample(
                    timestamp: Double(index) / 50.0,
                    userAcceleration: MotionVector3(x: 0, y: 0, z: 0.3),
                    gravity: MotionVector3(x: 0, y: 0, z: 1)
                )
            )
        }

        let first = builder.addLocationSample(sample(atMeters: 0, second: 0, heading: -1))
        #expect(first == nil)
        let second = builder.addLocationSample(sample(atMeters: 20, second: 4, heading: -1))
        #expect(second == nil)
        let completed = builder.addLocationSample(sample(atMeters: 40, second: 8, heading: -1))
        let window = try #require(completed)

        #expect(window.headingDegrees < 0)
    }

    @Test("upload payload encodes an unknown heading as explicit null")
    func payloadEncodesNullHeading() throws {
        let payload = UploadReadingPayload(
            lat: 44.65,
            lng: -63.57,
            roughnessRms: 0.05,
            speedKmh: 50,
            heading: -1,
            gpsAccuracyM: 5,
            isPothole: false,
            potholeMagnitude: nil,
            recordedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        #expect(payload.heading == nil)

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(payload)
        let json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])

        #expect(json.keys.contains("heading"))
        #expect(json["heading"] is NSNull)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(UploadReadingPayload.self, from: data)
        #expect(decoded == payload)
    }

    @Test("upload payload keeps a valid heading")
    func payloadKeepsValidHeading() throws {
        let payload = UploadReadingPayload(
            lat: 44.65,
            lng: -63.57,
            roughnessRms: 0.05,
            speedKmh: 50,
            heading: 92,
            gpsAccuracyM: 5,
            isPothole: false,
            potholeMagnitude: nil,
            recordedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let json = try #require(try JSONSerialization.jsonObject(with: try encoder.encode(payload)) as? [String: Any])
        #expect(json["heading"] as? Double == 92)
    }

    private func sample(atMeters meters: Double, second: TimeInterval, heading: Double) -> LocationSample {
        LocationSample(
            timestamp: second,
            latitude: -(meters * 180.0 / (.pi * 6_371_000.0)),
            longitude: 0,
            horizontalAccuracyMeters: 5,
            speedKmh: 40,
            headingDegrees: heading
        )
    }
}
