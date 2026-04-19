import Foundation

public enum SensorFixtureEvent: Equatable, Sendable {
    case gps(timestamp: Date, sample: LocationSample)
    case accel(timestamp: Date, userAcceleration: MotionVector3)
    case gravity(timestamp: Date, gravity: MotionVector3)
    case thermal(timestamp: Date, state: ThermalCollectionState)
    case activity(timestamp: Date, isAutomotive: Bool)

    public var timestamp: Date {
        switch self {
        case let .gps(timestamp, _),
             let .accel(timestamp, _),
             let .gravity(timestamp, _),
             let .thermal(timestamp, _),
             let .activity(timestamp, _):
            return timestamp
        }
    }
}

public struct SensorFixture: Equatable, Sendable {
    public let events: [SensorFixtureEvent]

    public init(events: [SensorFixtureEvent]) {
        self.events = events
    }
}

public enum SensorFixtureParseError: Error, Equatable, LocalizedError {
    case empty
    case invalidHeader
    case invalidColumnCount(line: Int)
    case nonMonotonicTimestamp(line: Int)
    case invalidTimestamp(line: Int)
    case invalidType(line: Int, value: String)
    case invalidNumber(line: Int, column: Int)
    case invalidThermalState(line: Int, value: String)

    public var errorDescription: String? {
        switch self {
        case .empty:
            return "fixture is empty"
        case .invalidHeader:
            return "fixture header is invalid"
        case let .invalidColumnCount(line):
            return "fixture line \(line) must have between 3 and 7 columns"
        case let .nonMonotonicTimestamp(line):
            return "fixture timestamp is not strictly monotonic at line \(line)"
        case let .invalidTimestamp(line):
            return "fixture timestamp is invalid at line \(line)"
        case let .invalidType(line, value):
            return "fixture type '\(value)' is invalid at line \(line)"
        case let .invalidNumber(line, column):
            return "fixture numeric value at line \(line), column \(column) is invalid"
        case let .invalidThermalState(line, value):
            return "fixture thermal value '\(value)' is invalid at line \(line)"
        }
    }
}

public enum SensorFixtureParser {
    public static func parse(csv: String) throws -> SensorFixture {
        let normalized = csv.replacingOccurrences(of: "\r\n", with: "\n")
        let lines = normalized.split(separator: "\n", omittingEmptySubsequences: false)

        guard !lines.isEmpty else {
            throw SensorFixtureParseError.empty
        }

        guard lines[0] == "timestamp,type,value1,value2,value3,value4,value5" else {
            throw SensorFixtureParseError.invalidHeader
        }

        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        var events: [SensorFixtureEvent] = []
        var previousTimestamp: Date?

        for (index, line) in lines.dropFirst().enumerated() {
            let lineNumber = index + 2
            guard !line.isEmpty else {
                continue
            }

            let rawColumns = line.split(separator: ",", omittingEmptySubsequences: false)
            guard rawColumns.count >= 3, rawColumns.count <= 7 else {
                throw SensorFixtureParseError.invalidColumnCount(line: lineNumber)
            }
            let columns = rawColumns + Array(repeating: Substring(""), count: max(0, 7 - rawColumns.count))

            guard let timestamp = formatter.date(from: String(columns[0])) else {
                throw SensorFixtureParseError.invalidTimestamp(line: lineNumber)
            }
            if let previousTimestamp, timestamp <= previousTimestamp {
                throw SensorFixtureParseError.nonMonotonicTimestamp(line: lineNumber)
            }
            previousTimestamp = timestamp

            let type = String(columns[1])
            let event: SensorFixtureEvent

            switch type {
            case "gps":
                event = .gps(
                    timestamp: timestamp,
                    sample: LocationSample(
                        timestamp: timestamp.timeIntervalSince1970,
                        latitude: try parseDouble(columns[2], line: lineNumber, column: 3),
                        longitude: try parseDouble(columns[3], line: lineNumber, column: 4),
                        horizontalAccuracyMeters: try parseDouble(columns[6], line: lineNumber, column: 7),
                        speedKmh: try parseDouble(columns[4], line: lineNumber, column: 5),
                        headingDegrees: try parseDouble(columns[5], line: lineNumber, column: 6)
                    )
                )
            case "accel":
                event = .accel(
                    timestamp: timestamp,
                    userAcceleration: MotionVector3(
                        x: try parseDouble(columns[2], line: lineNumber, column: 3),
                        y: try parseDouble(columns[3], line: lineNumber, column: 4),
                        z: try parseDouble(columns[4], line: lineNumber, column: 5)
                    )
                )
            case "gravity":
                event = .gravity(
                    timestamp: timestamp,
                    gravity: MotionVector3(
                        x: try parseDouble(columns[2], line: lineNumber, column: 3),
                        y: try parseDouble(columns[3], line: lineNumber, column: 4),
                        z: try parseDouble(columns[4], line: lineNumber, column: 5)
                    )
                )
            case "thermal":
                let rawValue = String(columns[2])
                guard let state = thermalState(from: rawValue) else {
                    throw SensorFixtureParseError.invalidThermalState(line: lineNumber, value: rawValue)
                }
                event = .thermal(timestamp: timestamp, state: state)
            case "activity":
                let activity = String(columns[2])
                event = .activity(timestamp: timestamp, isAutomotive: activity == "automotive")
            default:
                throw SensorFixtureParseError.invalidType(line: lineNumber, value: type)
            }

            events.append(event)
        }

        guard !events.isEmpty else {
            throw SensorFixtureParseError.empty
        }

        return SensorFixture(events: events)
    }

    private static func parseDouble(
        _ value: Substring,
        line: Int,
        column: Int
    ) throws -> Double {
        guard let parsed = Double(value) else {
            throw SensorFixtureParseError.invalidNumber(line: line, column: column)
        }
        return parsed
    }

    private static func thermalState(from rawValue: String) -> ThermalCollectionState? {
        switch rawValue {
        case "0":
            return .nominal
        case "1":
            return .fair
        case "2":
            return .serious
        case "3":
            return .critical
        default:
            return nil
        }
    }
}
