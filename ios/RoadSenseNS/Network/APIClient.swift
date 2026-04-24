import Foundation
import UIKit

enum APIClientError: LocalizedError {
    case invalidResponse
    case notFound
    case requestFailed(statusCode: Int, message: String?)

    var errorDescription: String? {
        switch self {
        case .invalidResponse:
            return "invalid_response"
        case .notFound:
            return "not_found"
        case let .requestFailed(statusCode, message):
            return message ?? "request_failed_\(statusCode)"
        }
    }
}

struct UploadAttemptSummary: Sendable {
    let result: UploadResponseParsingResult
}

enum PotholeActionUploadParsingResult: Sendable {
    case success(PotholeActionUploadResponse)
    case failure(UploadErrorEnvelope?)
}

struct PotholeActionAttemptSummary: Sendable {
    let statusCode: Int
    let requestID: String?
    let result: PotholeActionUploadParsingResult
    let retryAfterSeconds: TimeInterval?
}

enum PotholePhotoMetadataParsingResult: Sendable {
    case ready(PotholePhotoUploadResponse)
    case alreadyUploaded(UploadErrorEnvelope?)
    case failure(UploadErrorEnvelope?)
}

struct PotholePhotoMetadataAttemptSummary: Sendable {
    let statusCode: Int
    let requestID: String?
    let result: PotholePhotoMetadataParsingResult
    let retryAfterSeconds: TimeInterval?
}

struct SignedUploadAttemptSummary: Sendable {
    let statusCode: Int
}

final class APIClient {
    private let endpoints: Endpoints
    private let session: URLSession

    init(
        endpoints: Endpoints,
        session: URLSession = .shared
    ) {
        self.endpoints = endpoints
        self.session = session
    }

    func uploadReadings(
        batchID: UUID,
        deviceToken: String,
        readings: [UploadReadingPayload]
    ) async throws -> UploadAttemptSummary {
        let clientOSVersion = await MainActor.run {
            "iOS \(UIDevice.current.systemVersion)"
        }
        let request = try UploadRequestFactory.makeRequest(
            endpoints: endpoints,
            batchID: batchID,
            deviceToken: deviceToken,
            clientSentAt: Date(),
            clientAppVersion: appVersionString(),
            clientOSVersion: clientOSVersion,
            readings: readings
        )
        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw APIClientError.invalidResponse
        }

        let parsed = try UploadResponseParser.parse(
            statusCode: httpResponse.statusCode,
            headers: httpResponse.allHeaderFields,
            body: data
        )
        return UploadAttemptSummary(result: parsed)
    }

    func uploadPotholeAction(
        action: PotholeActionRecord,
        deviceToken: String,
        now: Date = Date()
    ) async throws -> PotholeActionAttemptSummary {
        let clientOSVersion = await MainActor.run {
            "iOS \(UIDevice.current.systemVersion)"
        }
        var request = URLRequest(url: endpoints.potholeActionsURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(endpoints.config.supabaseAnonKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(endpoints.config.supabaseAnonKey)", forHTTPHeaderField: "Authorization")
        request.httpBody = try UploadCodec.makeEncoder().encode(
            PotholeActionUploadRequest(
                actionID: action.id,
                deviceToken: deviceToken,
                clientSentAt: now,
                clientAppVersion: appVersionString(),
                clientOSVersion: clientOSVersion,
                actionType: action.actionType.rawValue,
                potholeReportID: action.potholeReportID,
                lat: action.latitude,
                lng: action.longitude,
                accuracyM: action.accuracyM,
                recordedAt: action.recordedAt
            )
        )

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw APIClientError.invalidResponse
        }

        let requestID = httpResponse.value(forHTTPHeaderField: "x-request-id")
        let retryAfterSeconds = retryAfter(from: httpResponse.allHeaderFields)
        let decoder = UploadCodec.makeDecoder()

        if httpResponse.statusCode == 200 {
            return PotholeActionAttemptSummary(
                statusCode: httpResponse.statusCode,
                requestID: requestID,
                result: .success(try decoder.decode(PotholeActionUploadResponse.self, from: data)),
                retryAfterSeconds: retryAfterSeconds
            )
        }

        return PotholeActionAttemptSummary(
            statusCode: httpResponse.statusCode,
            requestID: requestID,
            result: .failure(try? decoder.decode(UploadErrorEnvelope.self, from: data)),
            retryAfterSeconds: retryAfterSeconds
        )
    }

    func fetchSegmentDetail(id: UUID) async throws -> SegmentDetailResponse {
        var request = URLRequest(url: endpoints.segmentDetailURL(id: id))
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(endpoints.config.supabaseAnonKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(endpoints.config.supabaseAnonKey)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw APIClientError.invalidResponse
        }

        let parsed = try SegmentDetailResponseParser.parse(
            statusCode: httpResponse.statusCode,
            body: data
        )

        switch parsed {
        case let .found(segment):
            return segment
        case .notFound:
            throw APIClientError.notFound
        case let .failure(statusCode, errorEnvelope):
            throw APIClientError.requestFailed(
                statusCode: statusCode,
                message: errorEnvelope?.error
            )
        }
    }

    func beginPotholePhotoUpload(
        report: PotholeReportRecord,
        deviceToken: String,
        now: Date = Date()
    ) async throws -> PotholePhotoMetadataAttemptSummary {
        let clientOSVersion = await MainActor.run {
            "iOS \(UIDevice.current.systemVersion)"
        }
        var request = URLRequest(url: endpoints.potholePhotosURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(endpoints.config.supabaseAnonKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(endpoints.config.supabaseAnonKey)", forHTTPHeaderField: "Authorization")
        request.httpBody = try UploadCodec.makeEncoder().encode(
            PotholePhotoUploadRequest(
                reportID: report.id,
                segmentID: report.segmentID,
                deviceToken: deviceToken,
                clientSentAt: now,
                clientAppVersion: appVersionString(),
                clientOSVersion: clientOSVersion,
                lat: report.latitude,
                lng: report.longitude,
                accuracyM: report.accuracyM,
                capturedAt: report.capturedAt,
                contentType: "image/jpeg",
                byteSize: report.byteSize,
                sha256: report.sha256Hex
            )
        )

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw APIClientError.invalidResponse
        }

        let requestID = httpResponse.value(forHTTPHeaderField: "x-request-id")
        let retryAfterSeconds = retryAfter(from: httpResponse.allHeaderFields)
        let decoder = UploadCodec.makeDecoder()

        switch httpResponse.statusCode {
        case 200:
            return PotholePhotoMetadataAttemptSummary(
                statusCode: httpResponse.statusCode,
                requestID: requestID,
                result: .ready(try decoder.decode(PotholePhotoUploadResponse.self, from: data)),
                retryAfterSeconds: retryAfterSeconds
            )
        case 409:
            return PotholePhotoMetadataAttemptSummary(
                statusCode: httpResponse.statusCode,
                requestID: requestID,
                result: .alreadyUploaded(try? decoder.decode(UploadErrorEnvelope.self, from: data)),
                retryAfterSeconds: retryAfterSeconds
            )
        default:
            return PotholePhotoMetadataAttemptSummary(
                statusCode: httpResponse.statusCode,
                requestID: requestID,
                result: .failure(try? decoder.decode(UploadErrorEnvelope.self, from: data)),
                retryAfterSeconds: retryAfterSeconds
            )
        }
    }

    func uploadPotholePhotoFile(
        fileURL: URL,
        uploadURL: URL
    ) async throws -> SignedUploadAttemptSummary {
        var request = URLRequest(url: uploadURL)
        request.httpMethod = "PUT"
        request.setValue("image/jpeg", forHTTPHeaderField: "Content-Type")

        let (_, response) = try await session.upload(for: request, fromFile: fileURL)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw APIClientError.invalidResponse
        }

        return SignedUploadAttemptSummary(statusCode: httpResponse.statusCode)
    }

    private func appVersionString() -> String {
        let shortVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0"
        return "\(shortVersion) (\(build))"
    }

    private func retryAfter(from headers: [AnyHashable: Any]) -> TimeInterval? {
        let value = headers.first { key, _ in
            String(describing: key).caseInsensitiveCompare("Retry-After") == .orderedSame
        }?.value

        switch value {
        case let seconds as Int:
            return TimeInterval(seconds)
        case let seconds as String:
            return TimeInterval(seconds)
        default:
            return nil
        }
    }
}
