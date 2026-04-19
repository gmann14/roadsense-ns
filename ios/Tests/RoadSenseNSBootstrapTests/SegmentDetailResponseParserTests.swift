import Foundation
import Testing

@testable import RoadSenseNSBootstrap

struct SegmentDetailResponseParserTests {
    @Test
    func parsesSuccessfulSegmentDetailResponse() throws {
        let body = """
        {
          "id": "c8a1b2d3-1111-2222-3333-444444444444",
          "road_name": "Barrington Street",
          "road_type": "primary",
          "municipality": "Halifax",
          "length_m": 48.7,
          "has_speed_bump": false,
          "has_rail_crossing": false,
          "surface_type": "asphalt",
          "aggregate": {
            "avg_roughness_score": 0.72,
            "category": "rough",
            "confidence": "high",
            "total_readings": 137,
            "unique_contributors": 34,
            "pothole_count": 2,
            "trend": "worsening",
            "score_last_30d": 0.78,
            "score_30_60d": 0.69,
            "last_reading_at": "2026-04-16T22:15:00Z",
            "updated_at": "2026-04-17T03:15:00Z"
          },
          "history": [],
          "neighbors": null
        }
        """.data(using: .utf8)!

        let result = try SegmentDetailResponseParser.parse(statusCode: 200, body: body)

        guard case let .found(response) = result else {
            Issue.record("Expected found result")
            return
        }

        #expect(response.roadName == "Barrington Street")
        #expect(response.roadType == "primary")
        #expect(response.aggregate.category == "rough")
        #expect(response.aggregate.confidence == "high")
        #expect(response.aggregate.totalReadings == 137)
        #expect(response.history.isEmpty)
        #expect(response.neighbors == nil)
    }

    @Test
    func parsesNotFoundEnvelope() throws {
        let body = """
        {
          "error": "not_found"
        }
        """.data(using: .utf8)!

        let result = try SegmentDetailResponseParser.parse(statusCode: 404, body: body)

        guard case let .notFound(envelope) = result else {
            Issue.record("Expected notFound result")
            return
        }

        #expect(envelope?.error == "not_found")
    }

    @Test
    func preservesFailureStatusForUnexpectedErrors() throws {
        let body = Data("upstream unavailable".utf8)

        let result = try SegmentDetailResponseParser.parse(statusCode: 503, body: body)

        guard case let .failure(statusCode, envelope) = result else {
            Issue.record("Expected failure result")
            return
        }

        #expect(statusCode == 503)
        #expect(envelope == nil)
    }
}
