import Foundation

/// Scrubs location-bearing strings before they leave the device through a
/// third-party SDK (crash reporting). Pure so it can be unit tested without
/// the SDK.
public enum PrivacyRedactor {
    public static let redactionMarker = "[redacted]"

    /// HTTP breadcrumbs carry full request URLs: Mapbox static-image URLs
    /// embed a drive's centre coordinate, and API URLs carry query strings.
    /// They are dropped outright rather than scrubbed.
    public static func shouldDropBreadcrumb(category: String?, type: String?) -> Bool {
        let category = category?.lowercased() ?? ""
        let type = type?.lowercased() ?? ""
        return category == "http"
            || category.hasPrefix("http.")
            || type == "http"
            || category == "network"
    }

    /// Replaces decimal numbers precise enough to be coordinates (three or
    /// more fractional digits, i.e. ~100 m or better) with a marker.
    public static func redactCoordinates(in text: String) -> String {
        guard !text.isEmpty else {
            return text
        }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return coordinatePattern.stringByReplacingMatches(
            in: text,
            options: [],
            range: range,
            withTemplate: redactionMarker
        )
    }

    /// Reduces a URL to scheme + host. Paths can carry coordinates (Mapbox
    /// static images) and queries carry tokens.
    public static func redactURL(_ urlString: String) -> String {
        guard let components = URLComponents(string: urlString),
              let host = components.host else {
            return redactionMarker
        }
        let scheme = components.scheme ?? "https"
        return "\(scheme)://\(host)"
    }

    private static let coordinatePattern: NSRegularExpression = {
        // Force-try is safe: the pattern is a compile-time constant covered by tests.
        // swiftlint:disable:next force_try
        try! NSRegularExpression(pattern: #"-?\d{1,3}\.\d{3,}"#)
    }()
}
