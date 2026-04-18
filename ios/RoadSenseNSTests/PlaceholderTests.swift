import XCTest
@testable import RoadSenseNS

final class PlaceholderTests: XCTestCase {
    func testBootstrapConfigUsesFunctionsBaseURL() throws {
        let config = AppConfig(
            environment: .local,
            apiBaseURL: URL(string: "http://127.0.0.1:54321")!,
            mapboxAccessToken: "pk.test"
        )

        XCTAssertEqual(
            config.functionsBaseURL.absoluteString,
            "http://127.0.0.1:54321/functions/v1"
        )
    }
}
