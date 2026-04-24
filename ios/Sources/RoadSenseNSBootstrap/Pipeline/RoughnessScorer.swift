import Foundation

public struct RoughnessScorer: Sendable {
    public let sampleRateHz: Double
    public let cutoffHz: Double
    public let settleSampleCount: Int

    public init(
        sampleRateHz: Double = 50,
        cutoffHz: Double = 0.5,
        settleSampleCount: Int? = nil
    ) {
        self.sampleRateHz = sampleRateHz
        self.cutoffHz = cutoffHz
        self.settleSampleCount = settleSampleCount ?? Int(sampleRateHz)
    }

    public func score(samples: [MotionSample]) -> Double {
        score(verticalAccelerations: samples.map(\.verticalAcceleration))
    }

    public func score(verticalAccelerations: [Double]) -> Double {
        guard !verticalAccelerations.isEmpty else {
            return 0
        }

        var filter = HighPassBiquad.makeButterworth(
            sampleRateHz: sampleRateHz,
            cutoffHz: cutoffHz
        )

        if let firstSample = verticalAccelerations.first {
            for _ in 0..<settleSampleCount {
                _ = filter.apply(firstSample)
            }
        }

        let filtered = verticalAccelerations.map { filter.apply($0) }
        let meanSquare = filtered.reduce(0.0) { partialResult, sample in
            partialResult + (sample * sample)
        } / Double(filtered.count)

        return sqrt(meanSquare)
    }
}
