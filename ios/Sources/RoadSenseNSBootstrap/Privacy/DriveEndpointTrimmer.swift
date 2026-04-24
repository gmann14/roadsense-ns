import Foundation

public struct DriveSessionEndpoints: Equatable, Sendable {
    public let startedAt: Date
    public let endedAt: Date
    public let startLatitude: Double
    public let startLongitude: Double
    public let endLatitude: Double
    public let endLongitude: Double

    public init(
        startedAt: Date,
        endedAt: Date,
        startLatitude: Double,
        startLongitude: Double,
        endLatitude: Double,
        endLongitude: Double
    ) {
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.startLatitude = startLatitude
        self.startLongitude = startLongitude
        self.endLatitude = endLatitude
        self.endLongitude = endLongitude
    }
}

public enum DriveEndpointTrimmer {
    public static let trimWindowSeconds: TimeInterval = 60
    public static let trimRadiusMeters: Double = 300

    public static func shouldTrim(
        readingRecordedAt: Date,
        latitude: Double,
        longitude: Double,
        session: DriveSessionEndpoints
    ) -> Bool {
        if readingRecordedAt < session.startedAt.addingTimeInterval(trimWindowSeconds) {
            return true
        }

        if readingRecordedAt > session.endedAt.addingTimeInterval(-trimWindowSeconds) {
            return true
        }

        if PrivacyZoneFactory.distanceMeters(
            fromLatitude: latitude,
            fromLongitude: longitude,
            toLatitude: session.startLatitude,
            toLongitude: session.startLongitude
        ) < trimRadiusMeters {
            return true
        }

        if PrivacyZoneFactory.distanceMeters(
            fromLatitude: latitude,
            fromLongitude: longitude,
            toLatitude: session.endLatitude,
            toLongitude: session.endLongitude
        ) < trimRadiusMeters {
            return true
        }

        return false
    }
}
