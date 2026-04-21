import Foundation
import Testing

@testable import RoadSenseNSBootstrap

@Suite("Upload eligibility policy")
struct UploadEligibilityPolicyTests {
    @Test("allows uploads whenever network is available and no retry window is active")
    func allowsSatisfiedNetwork() {
        let decision = UploadEligibilityPolicy.shouldUpload(
            pendingCount: 50,
            network: NetworkPathSnapshot(status: .satisfied, isExpensive: true)
        )

        #expect(decision)
    }

    @Test("blocks uploads while waiting for retry")
    func blocksDuringRetryWindow() {
        let now = Date(timeIntervalSince1970: 1_000)
        let decision = UploadEligibilityPolicy.shouldUpload(
            pendingCount: 100,
            network: NetworkPathSnapshot(status: .satisfied, isExpensive: true),
            nextAttemptAt: now.addingTimeInterval(30),
            now: now
        )

        #expect(decision == false)
    }

    @Test("skips upload when there is nothing pending")
    func skipsWhenNoPendingData() {
        let decision = UploadEligibilityPolicy.shouldUpload(
            pendingCount: 0,
            network: NetworkPathSnapshot(status: .satisfied, isExpensive: true),
            nextAttemptAt: nil
        )

        #expect(decision == false)
    }

    @Test("skips upload entirely when network is unavailable")
    func skipsWhenOffline() {
        let decision = UploadEligibilityPolicy.shouldUpload(
            pendingCount: 500,
            network: NetworkPathSnapshot(status: .unsatisfied, isExpensive: false),
            nextAttemptAt: nil
        )

        #expect(decision == false)
    }
}
