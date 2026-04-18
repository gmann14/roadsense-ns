import Foundation

public struct Endpoints: Equatable, Sendable {
    public let config: AppConfig

    public init(config: AppConfig) {
        self.config = config
    }

    public var uploadReadingsURL: URL {
        config.functionsBaseURL.appendingPathComponent("upload-readings", isDirectory: false)
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
