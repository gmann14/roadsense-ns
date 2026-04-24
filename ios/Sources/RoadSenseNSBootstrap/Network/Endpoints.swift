import Foundation

public struct Endpoints: Equatable, Sendable {
    public let config: AppConfig

    public init(config: AppConfig) {
        self.config = config
    }

    public var uploadReadingsURL: URL {
        config.functionsBaseURL.appendingPathComponent("upload-readings", isDirectory: false)
    }

    public var potholeActionsURL: URL {
        config.functionsBaseURL.appendingPathComponent("pothole-actions", isDirectory: false)
    }

    public var potholePhotosURL: URL {
        config.functionsBaseURL.appendingPathComponent("pothole-photos", isDirectory: false)
    }

    public func segmentDetailURL(id: UUID) -> URL {
        config.functionsBaseURL
            .appendingPathComponent("segments", isDirectory: true)
            .appendingPathComponent(id.uuidString.lowercased(), isDirectory: false)
    }

    public var tileTemplateURLString: String {
        let base = config.functionsBaseURL.absoluteString
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let encodedAnonKey = config.supabaseAnonKey.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed)
            ?? config.supabaseAnonKey
        return base + "/tiles/{z}/{x}/{y}.mvt?apikey=" + encodedAnonKey
    }

    public func tileURL(z: Int, x: Int, y: Int, version: Int? = nil) -> URL {
        var url = config.functionsBaseURL
            .appendingPathComponent("tiles", isDirectory: true)
            .appendingPathComponent(String(z), isDirectory: true)
            .appendingPathComponent(String(x), isDirectory: true)
            .appendingPathComponent("\(y).mvt", isDirectory: false)

        if let version {
            var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
            components?.queryItems = [URLQueryItem(name: "v", value: String(version))]
            if let resolved = components?.url {
                url = resolved
            }
        }

        return url
    }
}
