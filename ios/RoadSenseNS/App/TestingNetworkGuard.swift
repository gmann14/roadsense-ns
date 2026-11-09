import Foundation

/// Keeps UI-test and screenshot launches from writing to a real backend.
///
/// Every build configuration points at the production API, and the
/// `ready-shell` scenario seeds queued readings and a pothole. With real keys
/// in a local secrets xcconfig, those launches used to upload the seeded data
/// (2026-11-09). The testing bootstrap therefore uses a session that fails
/// every request except GET and HEAD, so the map and segment detail still
/// read live data but nothing is ever written.
enum TestingNetworkGuard {
    static func makeReadOnlySession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [BlockWritesURLProtocol.self] + (configuration.protocolClasses ?? [])
        return URLSession(configuration: configuration)
    }
}

final class BlockWritesURLProtocol: URLProtocol {
    static let allowedMethods: Set<String> = ["GET", "HEAD"]

    override class func canInit(with request: URLRequest) -> Bool {
        !allowedMethods.contains((request.httpMethod ?? "GET").uppercased())
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
    }

    override func stopLoading() {}
}
