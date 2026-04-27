import Foundation

enum DriveListBucket: String, CaseIterable, Sendable {
    case today
    case yesterday
    case earlierThisWeek
    case earlier

    var displayName: String {
        switch self {
        case .today: return "Today"
        case .yesterday: return "Yesterday"
        case .earlierThisWeek: return "Earlier this week"
        case .earlier: return "Earlier"
        }
    }
}

struct DriveListSection: Identifiable, Equatable {
    let bucket: DriveListBucket
    let drives: [DriveSummary]

    var id: String { bucket.rawValue }
}

enum DriveListGrouper {
    static func group(
        _ summaries: [DriveSummary],
        now: Date,
        calendar: Calendar = .current
    ) -> [DriveListSection] {
        guard !summaries.isEmpty else { return [] }

        let startOfToday = calendar.startOfDay(for: now)
        let startOfYesterday = calendar.date(byAdding: .day, value: -1, to: startOfToday) ?? startOfToday
        let startOfWeek = startOfWeek(for: now, calendar: calendar) ?? startOfToday

        var bucketed: [DriveListBucket: [DriveSummary]] = [:]

        for summary in summaries {
            let bucket: DriveListBucket
            if summary.startedAt >= startOfToday {
                bucket = .today
            } else if summary.startedAt >= startOfYesterday {
                bucket = .yesterday
            } else if summary.startedAt >= startOfWeek {
                bucket = .earlierThisWeek
            } else {
                bucket = .earlier
            }
            bucketed[bucket, default: []].append(summary)
        }

        return DriveListBucket.allCases.compactMap { bucket -> DriveListSection? in
            guard let drives = bucketed[bucket], !drives.isEmpty else { return nil }
            return DriveListSection(bucket: bucket, drives: drives)
        }
    }

    private static func startOfWeek(for date: Date, calendar: Calendar) -> Date? {
        let components = calendar.dateComponents(
            [.yearForWeekOfYear, .weekOfYear],
            from: date
        )
        return calendar.date(from: components)
    }
}
