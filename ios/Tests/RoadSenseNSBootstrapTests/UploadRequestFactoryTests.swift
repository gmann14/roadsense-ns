import Foundation
import Testing

@testable import RoadSenseNSBootstrap

struct UploadRequestFactoryTests {
    @Test
    func buildsExpectedJSONRequest() throws {
        let config = AppConfig(
            environment: .local,
            apiBaseURL: URL(string: "http://127.0.0.1:54321")!,
            mapboxAccessToken: "pk.test-token",
            supabaseAnonKey: "anon.test-key"
        )
        let endpoints = Endpoints(config: config)
        let batchID = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!
        let recordedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let clientSentAt = Date(timeIntervalSince1970: 1_700_000_100)

        let request = try UploadRequestFactory.makeRequest(
            endpoints: endpoints,
            batchID: batchID,
            deviceToken: "11111111-2222-4333-8444-555555555555",
            clientSentAt: clientSentAt,
            clientAppVersion: "0.1.0 (1)",
            clientOSVersion: "iOS 26.3.1",
            readings: [
                UploadReadingPayload(
                    lat: 44.6488,
                    lng: -63.5752,
                    roughnessRms: 0.72,
                    speedKmh: 57.2,
                    heading: 92,
                    gpsAccuracyM: 6.4,
                    isPothole: true,
                    potholeMagnitude: 1.9,
                    recordedAt: recordedAt
                )
            ]
        )

        #expect(request.url == endpoints.uploadReadingsURL)
        #expect(request.httpMethod == "POST")
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
        #expect(request.value(forHTTPHeaderField: "apikey") == "anon.test-key")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer anon.test-key")

        let payload = try JSONSerialization.jsonObject(with: try #require(request.httpBody), options: []) as? [String: Any]
        #expect((payload?["batch_id"] as? String)?.lowercased() == batchID.uuidString.lowercased())
        #expect(payload?["device_token"] as? String == "11111111-2222-4333-8444-555555555555")
        #expect(payload?["client_sent_at"] as? String == "2023-11-14T22:15:00Z")
        #expect(payload?["client_app_version"] as? String == "0.1.0 (1)")
        #expect(payload?["client_os_version"] as? String == "iOS 26.3.1")

        let readings = payload?["readings"] as? [[String: Any]]
        #expect(readings?.count == 1)
        #expect(readings?.first?["lat"] as? Double == 44.6488)
        #expect(readings?.first?["lng"] as? Double == -63.5752)
        #expect(readings?.first?["roughness_rms"] as? Double == 0.72)
        #expect(readings?.first?["is_pothole"] as? Bool == true)
        #expect(readings?.first?["recorded_at"] as? String == "2023-11-14T22:13:20Z")
    }
}
