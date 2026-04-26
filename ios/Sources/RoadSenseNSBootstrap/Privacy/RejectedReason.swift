public enum RejectedReason: String, Codable, CaseIterable, Sendable {
    case outOfBounds = "out_of_bounds"
    case noSegmentMatch = "no_segment_match"
    case lowQuality = "low_quality"
    case futureTimestamp = "future_timestamp"
    case staleTimestamp = "stale_timestamp"
    case unpaved = "unpaved"
    case duplicateReading = "duplicate_reading"

    public var displayString: String {
        switch self {
        case .outOfBounds:
            return "Outside Nova Scotia coverage"
        case .noSegmentMatch:
            return "No nearby road match"
        case .lowQuality:
            return "GPS or motion quality too low"
        case .futureTimestamp:
            return "Timestamp was in the future"
        case .staleTimestamp:
            return "Recording was too old to accept"
        case .unpaved:
            return "Matched an unpaved road"
        case .duplicateReading:
            return "Already received by the server"
        }
    }
}
