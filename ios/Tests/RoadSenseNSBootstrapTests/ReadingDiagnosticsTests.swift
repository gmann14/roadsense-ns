import Foundation
import Testing

@testable import RoadSenseNSBootstrap

@Suite("Reading diagnostics")
struct ReadingDiagnosticsTests {
    @Test("each reason maps to a stable unit")
    func reasonsCarryUnits() {
        #expect(ReadingDiagnosticReason.privacyZone.unit == .locationSample)
        #expect(ReadingDiagnosticReason.collectionNotActive.unit == .collectionSample)
        #expect(ReadingDiagnosticReason.builderSampleCount.unit == .readingWindow)
        #expect(ReadingDiagnosticReason.qualitySpeed.unit == .readingWindow)
        #expect(ReadingDiagnosticReason.builderPartialAtSeal.unit == .readingWindow)
    }

    @Test("totals increment, sum by unit, and round-trip through JSON")
    func totalsBehaveLikeCounters() {
        var totals = ReadingDiagnosticTotals.empty
        totals.increment(.builderSampleCount)
        totals.increment(.builderSampleCount, by: 4)
        totals.increment(.qualitySpeed, by: 2)
        totals.increment(.privacyZone)

        #expect(totals.count(for: .builderSampleCount) == 5)
        #expect(totals.count(for: .qualitySpeed) == 2)
        #expect(totals.total(for: .readingWindow) == 7)
        #expect(totals.total(for: .locationSample) == 1)
        #expect(totals.total(for: .collectionSample) == 0)

        let json = totals.encodedJSON()
        #expect(json != nil)
        let decoded = ReadingDiagnosticTotals.decode(fromJSON: json)
        #expect(decoded == totals)
    }

    @Test("empty totals encode to nil so SwiftData blobs stay quiet")
    func emptyTotalsEncodeNil() {
        #expect(ReadingDiagnosticTotals.empty.encodedJSON() == nil)
        #expect(ReadingDiagnosticTotals.decode(fromJSON: nil).isEmpty)
        #expect(ReadingDiagnosticTotals.decode(fromJSON: "not-json").isEmpty)
    }

    @Test("unknown raw keys decode without throwing")
    func toleratesUnknownReasons() {
        let json = "{\"future_reason\":7,\"builder_sample_count\":3}"
        let totals = ReadingDiagnosticTotals.decode(fromJSON: json)
        #expect(totals.count(for: .builderSampleCount) == 3)
    }

    @Test("QualityRejectionReason maps to diagnostic reason")
    func qualityReasonsMapToDiagnostics() {
        #expect(QualityRejectionReason.gpsAccuracy.diagnosticReason == .qualityGpsAccuracy)
        #expect(QualityRejectionReason.speed.diagnosticReason == .qualitySpeed)
        #expect(QualityRejectionReason.sampleCount.diagnosticReason == .qualitySampleCount)
        #expect(QualityRejectionReason.duration.diagnosticReason == .qualityDuration)
        #expect(QualityRejectionReason.thermal.diagnosticReason == .qualityThermal)
    }
}
