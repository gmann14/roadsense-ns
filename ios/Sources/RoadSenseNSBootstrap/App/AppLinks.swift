import Foundation

/// Public web pages the app links to. Kept in one place so Settings,
/// onboarding and any future surface (App Intents, review notes) never drift.
///
/// App Review 5.1.1(i) requires an in-app privacy policy link; the Terms of
/// Use cover "informational only, never use the phone while driving".
public enum AppLinks {
    public static let privacyPolicy = URL(string: "https://nsroadsense.ca/privacy")!
    public static let termsOfUse = URL(string: "https://nsroadsense.ca/terms")!
    public static let support = URL(string: "https://nsroadsense.ca/support")!

    /// OpenStreetMap copyright page; the road network the app scores is
    /// derived from OSM data (ODbL).
    public static let openStreetMapCopyright = URL(string: "https://www.openstreetmap.org/copyright")!
    public static let mapboxAttribution = URL(string: "https://www.mapbox.com/about/maps/")!

    /// Ordered list for the "Legal & support" rows.
    public static let legalAndSupport: [(title: String, url: URL)] = [
        ("Privacy Policy", privacyPolicy),
        ("Terms of Use", termsOfUse),
        ("Support", support),
    ]
}
