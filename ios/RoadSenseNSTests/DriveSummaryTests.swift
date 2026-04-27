import Foundation
import SwiftData
import XCTest
@testable import RoadSense_NS

@MainActor
final class DriveSummaryTests: XCTestCase {
    func testRecentDriveSummariesGroupReadingsByDriveAndComputeDistance() throws {
        let container = try ModelContainerProvider.makeInMemory()
        let context = ModelContext(container)

        let driveOne = UUID()
        let driveTwo = UUID()
        let baseDate = Date(timeIntervalSince1970: 1_713_000_000)

        context.insert(
            DriveSessionRecord(
                id: driveOne,
                startedAt: baseDate,
                endedAt: baseDate.addingTimeInterval(420),
                startLatitude: 44.6488,
                startLongitude: -63.5752,
                endLatitude: 44.6520,
                endLongitude: -63.5710,
                isSealed: true
            )
        )

        // 4 readings forming an L-shape on Halifax peninsula. Total ~600 m.
        let driveOnePoints: [(Double, Double)] = [
            (44.6488, -63.5752),
            (44.6498, -63.5752),
            (44.6510, -63.5740),
            (44.6520, -63.5710),
        ]
        for (offset, point) in driveOnePoints.enumerated() {
            context.insert(
                ReadingRecord(
                    latitude: point.0,
                    longitude: point.1,
                    roughnessRMS: 0.04,
                    speedKMH: 50,
                    heading: 180,
                    gpsAccuracyM: 5,
                    isPothole: offset == 2,
                    potholeMagnitude: offset == 2 ? 1.7 : nil,
                    recordedAt: baseDate.addingTimeInterval(Double(offset) * 30),
                    driveSessionID: driveOne,
                    uploadReadyAt: baseDate.addingTimeInterval(Double(offset) * 30)
                )
            )
        }

        // Privacy-filtered reading on the same drive (should not affect distance/accepted count).
        context.insert(
            ReadingRecord(
                latitude: 44.6489,
                longitude: -63.5755,
                roughnessRMS: 0,
                speedKMH: 0,
                heading: 0,
                gpsAccuracyM: 12,
                isPothole: false,
                potholeMagnitude: nil,
                recordedAt: baseDate.addingTimeInterval(150),
                driveSessionID: driveOne,
                droppedByPrivacyZone: true
            )
        )

        // Second drive, 100% privacy filtered
        context.insert(
            DriveSessionRecord(
                id: driveTwo,
                startedAt: baseDate.addingTimeInterval(7_200),
                endedAt: baseDate.addingTimeInterval(7_500),
                startLatitude: 44.6480,
                startLongitude: -63.5760,
                endLatitude: 44.6481,
                endLongitude: -63.5761,
                isSealed: true
            )
        )
        context.insert(
            ReadingRecord(
                latitude: 44.6481,
                longitude: -63.5761,
                roughnessRMS: 0,
                speedKMH: 0,
                heading: 0,
                gpsAccuracyM: 8,
                isPothole: false,
                potholeMagnitude: nil,
                recordedAt: baseDate.addingTimeInterval(7_300),
                driveSessionID: driveTwo,
                droppedByPrivacyZone: true
            )
        )

        try context.save()

        let summaries = try ReadingStore(container: container).recentDriveSummaries()

        XCTAssertEqual(summaries.count, 2)

        // Sorted reverse-chronologically — drive two is more recent.
        XCTAssertEqual(summaries[0].id, driveTwo)
        XCTAssertEqual(summaries[1].id, driveOne)

        let drive1 = summaries[1]
        XCTAssertEqual(drive1.acceptedReadingCount, 4)
        XCTAssertEqual(drive1.privacyFilteredReadingCount, 1)
        XCTAssertEqual(drive1.potholeCount, 1)
        XCTAssertGreaterThan(drive1.distanceKm, 0.4)
        XCTAssertLessThan(drive1.distanceKm, 0.7)
        XCTAssertNotNil(drive1.bbox)
        let drive1Box = try XCTUnwrap(drive1.bbox)
        XCTAssertEqual(drive1Box.minLatitude, 44.6488, accuracy: 1e-6)
        XCTAssertEqual(drive1Box.maxLatitude, 44.6520, accuracy: 1e-6)

        let drive2 = summaries[0]
        XCTAssertEqual(drive2.acceptedReadingCount, 0)
        XCTAssertEqual(drive2.privacyFilteredReadingCount, 1)
        XCTAssertEqual(drive2.distanceKm, 0)
        XCTAssertTrue(drive2.hasOnlyPrivacyFilteredData)
        let drive2Box = try XCTUnwrap(drive2.bbox)
        XCTAssertEqual(drive2Box.minLatitude, 44.6480, accuracy: 1e-6)
    }

    func testDeleteDriveSessionRemovesSessionAndItsReadings() throws {
        let container = try ModelContainerProvider.makeInMemory()
        let context = ModelContext(container)

        let driveOne = UUID()
        let driveTwo = UUID()
        let baseDate = Date(timeIntervalSince1970: 1_713_000_000)

        context.insert(
            DriveSessionRecord(
                id: driveOne,
                startedAt: baseDate,
                startLatitude: 44.6488,
                startLongitude: -63.5752,
                isSealed: true
            )
        )
        context.insert(
            DriveSessionRecord(
                id: driveTwo,
                startedAt: baseDate.addingTimeInterval(3_600),
                startLatitude: 44.6500,
                startLongitude: -63.5800,
                isSealed: true
            )
        )

        for index in 0..<3 {
            context.insert(
                ReadingRecord(
                    latitude: 44.6488,
                    longitude: -63.5752,
                    roughnessRMS: 0.05,
                    speedKMH: 40,
                    heading: 180,
                    gpsAccuracyM: 5,
                    isPothole: false,
                    potholeMagnitude: nil,
                    recordedAt: baseDate.addingTimeInterval(Double(index) * 10),
                    driveSessionID: driveOne
                )
            )
        }

        for index in 0..<2 {
            context.insert(
                ReadingRecord(
                    latitude: 44.6500,
                    longitude: -63.5800,
                    roughnessRMS: 0.05,
                    speedKMH: 40,
                    heading: 180,
                    gpsAccuracyM: 5,
                    isPothole: false,
                    potholeMagnitude: nil,
                    recordedAt: baseDate.addingTimeInterval(3_600 + Double(index) * 10),
                    driveSessionID: driveTwo
                )
            )
        }

        try context.save()

        let store = ReadingStore(container: container)
        try store.deleteDriveSession(id: driveOne)

        let remainingSessions = try context.fetch(FetchDescriptor<DriveSessionRecord>())
        XCTAssertEqual(remainingSessions.map(\.id), [driveTwo])

        let remainingReadings = try context.fetch(FetchDescriptor<ReadingRecord>())
        XCTAssertEqual(remainingReadings.count, 2)
        XCTAssertTrue(remainingReadings.allSatisfy { $0.driveSessionID == driveTwo })
    }

    func testHaversineDistanceIsZeroForSinglePoint() {
        XCTAssertEqual(DriveStore.haversineDistanceKm(coordinates: []), 0)
        XCTAssertEqual(DriveStore.haversineDistanceKm(coordinates: [(44.6, -63.6)]), 0)
    }

    func testHaversineDistanceMatchesKnownTwoPointSegment() {
        // From CN Tower (43.6426, -79.3871) to Toronto City Hall (43.6534, -79.3839): ~1.21 km
        let distance = DriveStore.haversineDistanceKm(coordinates: [
            (43.6426, -79.3871),
            (43.6534, -79.3839),
        ])
        XCTAssertEqual(distance, 1.21, accuracy: 0.05)
    }

    func testRecentDriveSummariesRespectsLimit() throws {
        let container = try ModelContainerProvider.makeInMemory()
        let context = ModelContext(container)
        let baseDate = Date(timeIntervalSince1970: 1_713_000_000)

        for index in 0..<5 {
            context.insert(
                DriveSessionRecord(
                    id: UUID(),
                    startedAt: baseDate.addingTimeInterval(Double(index) * 3_600),
                    startLatitude: 44.6488,
                    startLongitude: -63.5752,
                    isSealed: true
                )
            )
        }
        try context.save()

        let summaries = try ReadingStore(container: container).recentDriveSummaries(limit: 3)
        XCTAssertEqual(summaries.count, 3)
    }
}
