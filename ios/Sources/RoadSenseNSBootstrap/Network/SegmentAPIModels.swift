import Foundation

public struct SegmentDetailResponse: Codable, Equatable, Sendable, Identifiable {
    public let id: UUID
    public let roadName: String
    public let roadType: String
    public let municipality: String
    public let lengthM: Double
    public let hasSpeedBump: Bool
    public let hasRailCrossing: Bool
    public let surfaceType: String
    public let aggregate: SegmentAggregate
    public let potholes: [SegmentPothole]
    public let history: [SegmentHistoryPoint]
    public let neighbors: SegmentNeighbors?

    public init(
        id: UUID,
        roadName: String,
        roadType: String,
        municipality: String,
        lengthM: Double,
        hasSpeedBump: Bool,
        hasRailCrossing: Bool,
        surfaceType: String,
        aggregate: SegmentAggregate,
        potholes: [SegmentPothole],
        history: [SegmentHistoryPoint],
        neighbors: SegmentNeighbors?
    ) {
        self.id = id
        self.roadName = roadName
        self.roadType = roadType
        self.municipality = municipality
        self.lengthM = lengthM
        self.hasSpeedBump = hasSpeedBump
        self.hasRailCrossing = hasRailCrossing
        self.surfaceType = surfaceType
        self.aggregate = aggregate
        self.potholes = potholes
        self.history = history
        self.neighbors = neighbors
    }

    enum CodingKeys: String, CodingKey {
        case id
        case roadName = "road_name"
        case roadType = "road_type"
        case municipality
        case lengthM = "length_m"
        case hasSpeedBump = "has_speed_bump"
        case hasRailCrossing = "has_rail_crossing"
        case surfaceType = "surface_type"
        case aggregate
        case potholes
        case history
        case neighbors
    }
}

public struct SegmentPothole: Codable, Equatable, Sendable, Identifiable {
    public let id: UUID
    public let status: String
    public let latitude: Double
    public let longitude: Double
    public let confirmationCount: Int
    public let uniqueReporters: Int
    public let lastConfirmedAt: Date

    public init(
        id: UUID,
        status: String,
        latitude: Double,
        longitude: Double,
        confirmationCount: Int,
        uniqueReporters: Int,
        lastConfirmedAt: Date
    ) {
        self.id = id
        self.status = status
        self.latitude = latitude
        self.longitude = longitude
        self.confirmationCount = confirmationCount
        self.uniqueReporters = uniqueReporters
        self.lastConfirmedAt = lastConfirmedAt
    }

    enum CodingKeys: String, CodingKey {
        case id
        case status
        case latitude = "lat"
        case longitude = "lng"
        case confirmationCount = "confirmation_count"
        case uniqueReporters = "unique_reporters"
        case lastConfirmedAt = "last_confirmed_at"
    }
}

public struct SegmentAggregate: Codable, Equatable, Sendable {
    public let avgRoughnessScore: Double
    public let category: String
    public let confidence: String
    public let totalReadings: Int
    public let uniqueContributors: Int
    public let potholeCount: Int
    public let trend: String
    public let scoreLast30D: Double?
    public let score30To60D: Double?
    public let lastReadingAt: Date?
    public let updatedAt: Date

    public init(
        avgRoughnessScore: Double,
        category: String,
        confidence: String,
        totalReadings: Int,
        uniqueContributors: Int,
        potholeCount: Int,
        trend: String,
        scoreLast30D: Double?,
        score30To60D: Double?,
        lastReadingAt: Date?,
        updatedAt: Date
    ) {
        self.avgRoughnessScore = avgRoughnessScore
        self.category = category
        self.confidence = confidence
        self.totalReadings = totalReadings
        self.uniqueContributors = uniqueContributors
        self.potholeCount = potholeCount
        self.trend = trend
        self.scoreLast30D = scoreLast30D
        self.score30To60D = score30To60D
        self.lastReadingAt = lastReadingAt
        self.updatedAt = updatedAt
    }

    enum CodingKeys: String, CodingKey {
        case avgRoughnessScore = "avg_roughness_score"
        case category
        case confidence
        case totalReadings = "total_readings"
        case uniqueContributors = "unique_contributors"
        case potholeCount = "pothole_count"
        case trend
        case scoreLast30D = "score_last_30d"
        case score30To60D = "score_30_60d"
        case lastReadingAt = "last_reading_at"
        case updatedAt = "updated_at"
    }
}

public struct SegmentHistoryPoint: Codable, Equatable, Sendable {
    public init() {}
}

public struct SegmentNeighbors: Codable, Equatable, Sendable {
    public init() {}
}
