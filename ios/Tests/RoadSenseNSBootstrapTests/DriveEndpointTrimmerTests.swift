import Foundation
import Testing

@testable import RoadSenseNSBootstrap

@Suite("Drive endpoint trimmer")
struct DriveEndpointTrimmerTests {
    private let session = DriveSessionEndpoints(
        startedAt: Date(timeIntervalSince1970: 1_000),
        endedAt: Date(timeIntervalSince1970: 1_600),
        startLatitude: 44.6488,
        startLongitude: -63.5752,
        endLatitude: 44.7090,
        endLongitude: -63.6220
    )

    @Test("trims readings during the first minute")
    func trimsStartWindow() {
        let shouldTrim = DriveEndpointTrimmer.shouldTrim(
            readingRecordedAt: Date(timeIntervalSince1970: 1_030),
            latitude: 44.6600,
            longitude: -63.5900,
            session: session
        )

        #expect(shouldTrim)
    }

    @Test("trims readings during the last minute")
    func trimsEndWindow() {
        let shouldTrim = DriveEndpointTrimmer.shouldTrim(
            readingRecordedAt: Date(timeIntervalSince1970: 1_580),
            latitude: 44.6900,
            longitude: -63.6100,
            session: session
        )

        #expect(shouldTrim)
    }

    @Test("trims readings near the start coordinate even after the time window")
    func trimsNearStartCoordinate() {
        let shouldTrim = DriveEndpointTrimmer.shouldTrim(
            readingRecordedAt: Date(timeIntervalSince1970: 1_120),
            latitude: 44.6500,
            longitude: -63.5750,
            session: session
        )

        #expect(shouldTrim)
    }

    @Test("keeps mid-drive readings outside both endpoint zones")
    func keepsMidDriveReading() {
        let shouldTrim = DriveEndpointTrimmer.shouldTrim(
            readingRecordedAt: Date(timeIntervalSince1970: 1_300),
            latitude: 44.6800,
            longitude: -63.6000,
            session: session
        )

        #expect(shouldTrim == false)
    }
}
