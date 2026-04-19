import Foundation

public struct SensorCheckpoint: Equatable, Sendable, Codable {
    public let savedAt: Date
    public let wasCollecting: Bool
    public let latestLocation: LocationSample?
    public let recentPotholes: [PotholeCandidate]
    public let readingBuilder: ReadingBuilder.Snapshot
    public let potholeDetector: PotholeDetector.Snapshot

    public init(
        savedAt: Date,
        wasCollecting: Bool,
        latestLocation: LocationSample?,
        recentPotholes: [PotholeCandidate],
        readingBuilder: ReadingBuilder.Snapshot,
        potholeDetector: PotholeDetector.Snapshot
    ) {
        self.savedAt = savedAt
        self.wasCollecting = wasCollecting
        self.latestLocation = latestLocation
        self.recentPotholes = recentPotholes
        self.readingBuilder = readingBuilder
        self.potholeDetector = potholeDetector
    }

    public func isFresh(at now: Date, maxAge: TimeInterval) -> Bool {
        now.timeIntervalSince(savedAt) <= maxAge
    }
}
