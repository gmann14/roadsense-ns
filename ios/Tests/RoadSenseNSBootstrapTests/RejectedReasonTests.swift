import Testing
@testable import RoadSenseNSBootstrap

struct RejectedReasonTests {
    @Test
    func staysAlignedWithBackendReasonCodes() {
        #expect(RejectedReason.allCases.map(\.rawValue) == [
            "out_of_bounds",
            "no_segment_match",
            "low_quality",
            "future_timestamp",
            "stale_timestamp",
            "unpaved",
            "duplicate_reading",
        ])
    }
}
