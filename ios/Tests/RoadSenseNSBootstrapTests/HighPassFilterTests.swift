import Foundation
import Testing

@testable import RoadSenseNSBootstrap

@Suite("High-pass filter")
struct HighPassFilterTests {
    @Test("strongly attenuates a 0.1 Hz sine wave")
    func attenuatesLowFrequencySignal() {
        var filter = HighPassBiquad.makeButterworth(sampleRateHz: 50, cutoffHz: 0.5)
        let input = sineWave(frequencyHz: 0.1, sampleRateHz: 50, sampleCount: 2_000)
        let output = input.map { filter.apply($0) }

        let ratio = rms(output.suffix(1_500)) / rms(Array(input.suffix(1_500)))

        #expect(ratio < 0.05)
    }

    @Test("preserves a 5 Hz sine wave")
    func preservesHighFrequencySignal() {
        var filter = HighPassBiquad.makeButterworth(sampleRateHz: 50, cutoffHz: 0.5)
        let input = sineWave(frequencyHz: 5, sampleRateHz: 50, sampleCount: 2_000)
        let output = input.map { filter.apply($0) }

        let ratio = rms(output.suffix(1_500)) / rms(Array(input.suffix(1_500)))

        #expect(ratio > 0.9)
        #expect(ratio < 1.1)
    }

    private func sineWave(frequencyHz: Double, sampleRateHz: Double, sampleCount: Int) -> [Double] {
        (0..<sampleCount).map { index in
            let time = Double(index) / sampleRateHz
            return sin(2 * .pi * frequencyHz * time)
        }
    }

    private func rms<S: Sequence>(_ samples: S) -> Double where S.Element == Double {
        let values = Array(samples)
        let meanSquare = values.reduce(0.0) { partialResult, sample in
            partialResult + (sample * sample)
        } / Double(values.count)

        return sqrt(meanSquare)
    }
}
