import Foundation

public enum RetentionPolicy {
    public static func pruneUploadedReadings(
        _ readings: [QueueReadingRecord],
        now: Date
    ) -> [QueueReadingRecord] {
        let cutoff = now.addingTimeInterval(-30 * 24 * 60 * 60)

        return readings.filter { reading in
            guard let uploadedAt = reading.uploadedAt else {
                return true
            }

            return uploadedAt >= cutoff
        }
    }
}
