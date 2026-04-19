import Testing

@testable import RoadSenseNSBootstrap

@Suite("Upload eligibility policy")
struct UploadEligibilityPolicyTests {
    @Test("skips small batches on cellular when cellular uploads are disabled")
    func skipsSmallBatchOnCellular() {
        let decision = UploadEligibilityPolicy.shouldUpload(
            pendingCount: 50,
            network: NetworkPathSnapshot(status: .satisfied, isExpensive: true),
            allowCellularUpload: false
        )

        #expect(decision == false)
    }

    @Test("allows larger batches even when cellular uploads are disabled")
    func allowsLargeBatch() {
        let decision = UploadEligibilityPolicy.shouldUpload(
            pendingCount: 100,
            network: NetworkPathSnapshot(status: .satisfied, isExpensive: true),
            allowCellularUpload: false
        )

        #expect(decision)
    }

    @Test("allows cellular when the user opted in")
    func allowsCellularWhenEnabled() {
        let decision = UploadEligibilityPolicy.shouldUpload(
            pendingCount: 50,
            network: NetworkPathSnapshot(status: .satisfied, isExpensive: true),
            allowCellularUpload: true
        )

        #expect(decision)
    }

    @Test("skips upload entirely when network is unavailable")
    func skipsWhenOffline() {
        let decision = UploadEligibilityPolicy.shouldUpload(
            pendingCount: 500,
            network: NetworkPathSnapshot(status: .unsatisfied, isExpensive: false),
            allowCellularUpload: true
        )

        #expect(decision == false)
    }
}
