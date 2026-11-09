import Foundation
import XCTest
@testable import RoadSense_NS

final class TestingNetworkGuardTests: XCTestCase {
    func testWritesAreInterceptedAndReadsPassThrough() {
        let url = URL(string: "https://api.nsroadsense.ca/functions/v1/upload-readings")!
        for method in ["POST", "PUT", "PATCH", "DELETE", "post"] {
            var request = URLRequest(url: url)
            request.httpMethod = method
            XCTAssertTrue(BlockWritesURLProtocol.canInit(with: request), "\(method) must be blocked")
        }
        for method in ["GET", "HEAD", "get"] {
            var request = URLRequest(url: url)
            request.httpMethod = method
            XCTAssertFalse(BlockWritesURLProtocol.canInit(with: request), "\(method) must pass through")
        }
    }

    func testPostThroughReadOnlySessionFailsWithoutReachingTheNetwork() async {
        let session = TestingNetworkGuard.makeReadOnlySession()
        // An unroutable host: if the guard failed, this would be a DNS or
        // connection error rather than notConnectedToInternet.
        var request = URLRequest(url: URL(string: "https://guard-test.invalid/functions/v1/upload-readings")!)
        request.httpMethod = "POST"
        request.httpBody = Data("{}".utf8)

        do {
            _ = try await session.data(for: request)
            XCTFail("POST through the read-only session must fail")
        } catch let error as URLError {
            XCTAssertEqual(error.code, .notConnectedToInternet)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }
}
