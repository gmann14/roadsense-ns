import Foundation

struct ManualPotholeLocator {
    private let reactionOffsetSeconds: TimeInterval
    private let bufferWindowSeconds: TimeInterval

    init(
        reactionOffsetSeconds: TimeInterval = 0.75,
        bufferWindowSeconds: TimeInterval = 3
    ) {
        self.reactionOffsetSeconds = reactionOffsetSeconds
        self.bufferWindowSeconds = bufferWindowSeconds
    }

    func locate(
        tapTimestamp: Date,
        recentSamples: [LocationSample],
        latestSample: LocationSample?
    ) -> LocationSample? {
        let tapTime = tapTimestamp.timeIntervalSince1970
        let targetTime = tapTime - reactionOffsetSeconds
        let buffered = recentSamples.filter { sample in
            let age = tapTime - sample.timestamp
            return age >= 0 && age <= bufferWindowSeconds
        }

        if let closest = buffered.min(by: {
            abs($0.timestamp - targetTime) < abs($1.timestamp - targetTime)
        }) {
            return closest
        }

        return latestSample
    }
}
