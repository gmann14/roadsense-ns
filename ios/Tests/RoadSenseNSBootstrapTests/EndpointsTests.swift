import Foundation
import Testing
@testable import RoadSenseNSBootstrap

struct EndpointsTests {
    @Test
    func buildsUploadAndTileURLsFromConfigurableBase() {
        let config = AppConfig(
            environment: .local,
            apiBaseURL: URL(string: "http://127.0.0.1:54321")!,
            mapboxAccessToken: "pk.test-token"
        )
        let endpoints = Endpoints(config: config)

        #expect(endpoints.uploadReadingsURL.absoluteString == "http://127.0.0.1:54321/functions/v1/upload-readings")
        #expect(endpoints.tileURL(z: 14, x: 5299, y: 5915).absoluteString == "http://127.0.0.1:54321/functions/v1/tiles/14/5299/5915.mvt")
        #expect(endpoints.tileURL(z: 14, x: 5299, y: 5915, version: 197).absoluteString == "http://127.0.0.1:54321/functions/v1/tiles/14/5299/5915.mvt?v=197")
    }
}
