import Foundation
import SwiftData
import XCTest
@testable import RoadSense_NS

@MainActor
final class UploadRuntimeTests: XCTestCase {
    func testUploadDrainCoordinatorCoalescesConcurrentRequests() async {
        let uploader = BlockingUploadDrainer()
        let coordinator = UploadDrainCoordinator(
            uploader: uploader,
            logger: .upload
        )

        let started = expectation(description: "drain started")
        uploader.onStart = { started.fulfill() }

        let first = Task { @MainActor in
            await coordinator.requestDrain(reason: .foreground)
        }
        await fulfillment(of: [started], timeout: 1.0)

        let second = Task { @MainActor in
            await coordinator.requestDrain(reason: .diagnosticsRetry)
        }

        XCTAssertEqual(uploader.callCount, 1)

        uploader.release()

        let firstResult = await first.value
        let secondResult = await second.value

        XCTAssertTrue(firstResult)
        XCTAssertTrue(secondResult)
        XCTAssertEqual(uploader.callCount, 1)
    }

    func testBackgroundUploadDrainRunnerCompletesAndReschedulesAfterSuccess() async {
        let coordinator = FakeUploadDrainCoordinator()
        coordinator.finish(with: true)

        var completionResults: [Bool] = []
        var scheduledDates: [Date] = []
        let now = Date(timeIntervalSince1970: 1_713_000_000)

        let execution = BackgroundUploadDrainRunner.makeExecution(
            coordinator: coordinator,
            logger: .upload,
            nowProvider: { now },
            scheduleNext: { scheduledDates.append($0) },
            setTaskCompleted: { completionResults.append($0) }
        )

        await execution.task.value

        XCTAssertEqual(coordinator.requestCount, 1)
        XCTAssertEqual(coordinator.requestedReasons, [.backgroundTask])
        XCTAssertEqual(coordinator.cancelCount, 0)
        XCTAssertEqual(completionResults, [true])
        XCTAssertEqual(scheduledDates, [now.addingTimeInterval(15 * 60)])
    }

    func testBackgroundUploadDrainRunnerCancelsActiveDrainAndReschedules() async {
        let coordinator = FakeUploadDrainCoordinator()
        let started = expectation(description: "background drain requested")
        coordinator.onRequest = { started.fulfill() }

        var completionResults: [Bool] = []
        var scheduledDates: [Date] = []
        let now = Date(timeIntervalSince1970: 1_713_000_000)

        let execution = BackgroundUploadDrainRunner.makeExecution(
            coordinator: coordinator,
            logger: .upload,
            nowProvider: { now },
            scheduleNext: { scheduledDates.append($0) },
            setTaskCompleted: { completionResults.append($0) }
        )

        await fulfillment(of: [started], timeout: 1.0)
        execution.expirationHandler()
        await execution.task.value

        XCTAssertEqual(coordinator.requestCount, 1)
        XCTAssertEqual(coordinator.cancelCount, 1)
        XCTAssertEqual(completionResults, [false])
        XCTAssertEqual(scheduledDates, [now.addingTimeInterval(15 * 60)])
    }

    func testUploadQueueStatusSummaryReportsRetryFailuresAndLastSuccess() throws {
        let container = try ModelContainerProvider.makeInMemory()
        let context = ModelContext(container)
        let now = Date(timeIntervalSince1970: 1_713_000_000)

        context.insert(
            ReadingRecord(
                latitude: 44.6488,
                longitude: -63.5752,
                roughnessRMS: 1.2,
                speedKMH: 50,
                heading: 180,
                gpsAccuracyM: 5,
                isPothole: false,
                potholeMagnitude: nil,
                recordedAt: now
            )
        )
        context.insert(
            UploadBatch(
                createdAt: now.addingTimeInterval(-600),
                attemptCount: 1,
                lastAttemptAt: now.addingTimeInterval(-300),
                nextAttemptAt: nil,
                status: .succeeded,
                readingCount: 100
            )
        )
        context.insert(
            UploadBatch(
                createdAt: now.addingTimeInterval(-120),
                attemptCount: 2,
                lastAttemptAt: now.addingTimeInterval(-60),
                nextAttemptAt: now.addingTimeInterval(45),
                status: .pending,
                readingCount: 50
            )
        )
        context.insert(
            UploadBatch(
                createdAt: now.addingTimeInterval(-30),
                attemptCount: 3,
                lastAttemptAt: now.addingTimeInterval(-10),
                nextAttemptAt: nil,
                status: .failedPermanent,
                readingCount: 25,
                firstErrorMessage: "upload_failed"
            )
        )
        try context.save()

        let summary = try UploadQueueStore(container: container).statusSummary(now: now)

        XCTAssertEqual(summary.pendingReadingCount, 1)
        XCTAssertEqual(summary.failedPermanentBatchCount, 1)
        XCTAssertEqual(summary.nextRetryAt, now.addingTimeInterval(45))
        XCTAssertEqual(summary.lastSuccessfulUploadAt, now.addingTimeInterval(-300))
    }
}

@MainActor
private final class BlockingUploadDrainer: UploadDrainPerforming {
    var onStart: (() -> Void)?
    private(set) var callCount = 0
    private var isReleased = false
    private var result: Result<Void, Error> = .success(())

    func drainUntilBlocked(nowProvider: @escaping @Sendable () -> Date) async throws {
        callCount += 1
        onStart?()

        while !isReleased {
            try Task.checkCancellation()
            try await Task.sleep(nanoseconds: 10_000_000)
        }

        try result.get()
    }

    func release(with result: Result<Void, Error> = .success(())) {
        self.result = result
        isReleased = true
    }
}

@MainActor
private final class FakeUploadDrainCoordinator: UploadDrainCoordinating {
    var onRequest: (() -> Void)?
    private(set) var requestCount = 0
    private(set) var cancelCount = 0
    private(set) var requestedReasons: [UploadDrainReason] = []
    private var shouldFinish = false
    private var nextResult = true

    func requestDrain(reason: UploadDrainReason) async -> Bool {
        requestCount += 1
        requestedReasons.append(reason)
        onRequest?()

        while !shouldFinish {
            if cancelCount > 0 {
                return false
            }
            await Task.yield()
        }

        return nextResult
    }

    func cancelActiveDrain() {
        cancelCount += 1
    }

    func finish(with result: Bool) {
        nextResult = result
        shouldFinish = true
    }
}
