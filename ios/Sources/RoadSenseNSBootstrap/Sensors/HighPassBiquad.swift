import Foundation

public struct HighPassBiquad: Sendable {
    public let b0: Double
    public let b1: Double
    public let b2: Double
    public let a1: Double
    public let a2: Double

    private var x1 = 0.0
    private var x2 = 0.0
    private var y1 = 0.0
    private var y2 = 0.0

    public init(
        b0: Double,
        b1: Double,
        b2: Double,
        a1: Double,
        a2: Double
    ) {
        self.b0 = b0
        self.b1 = b1
        self.b2 = b2
        self.a1 = a1
        self.a2 = a2
    }

    public mutating func apply(_ x: Double) -> Double {
        let y = b0 * x + b1 * x1 + b2 * x2 - a1 * y1 - a2 * y2
        x2 = x1
        x1 = x
        y2 = y1
        y1 = y
        return y
    }

    public static func makeButterworth(
        sampleRateHz: Double,
        cutoffHz: Double
    ) -> HighPassBiquad {
        let q = 1.0 / sqrt(2.0)
        let w0 = 2.0 * .pi * cutoffHz / sampleRateHz
        let cosW0 = cos(w0)
        let sinW0 = sin(w0)
        let alpha = sinW0 / (2.0 * q)

        let rawB0 = (1.0 + cosW0) / 2.0
        let rawB1 = -(1.0 + cosW0)
        let rawB2 = (1.0 + cosW0) / 2.0
        let a0 = 1.0 + alpha
        let rawA1 = -2.0 * cosW0
        let rawA2 = 1.0 - alpha

        return HighPassBiquad(
            b0: rawB0 / a0,
            b1: rawB1 / a0,
            b2: rawB2 / a0,
            a1: rawA1 / a0,
            a2: rawA2 / a0
        )
    }
}
