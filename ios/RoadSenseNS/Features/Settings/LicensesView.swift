import SwiftUI

/// Reachable from Settings → About → Licenses. Lists open-source licenses for
/// every third-party component the app ships with.
///
/// Reference: §12.5.4 of `docs/reviews/2026-04-24-design-audit.md`.
///
/// To add a license: append a `License` to `LicensesView.allLicenses`. Keep the
/// `excerpt` short (one paragraph max); the full text reads as cleaner inside
/// the disclosure.
struct LicensesView: View {
    static let allLicenses: [License] = [
        License(
            name: "Sentry Cocoa",
            url: URL(string: "https://github.com/getsentry/sentry-cocoa"),
            licenseName: "MIT License",
            excerpt: "Sentry Cocoa SDK is used for crash reporting only. RoadSense NS configures it to never collect location, route, or contribution data."
        )
        // Fraunces, IBM Plex Mono, and any other future bundled fonts will be
        // added here under SIL OFL when the asset bundles ship.
    ]

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DesignTokens.Space.lg) {
                introCard
                ForEach(Self.allLicenses) { license in
                    licenseCard(license)
                }
            }
            .padding(.horizontal, DesignTokens.Space.xl)
            .padding(.top, DesignTokens.Space.lg)
            .padding(.bottom, DesignTokens.Space.xxxl)
        }
        .background(backgroundGradient.ignoresSafeArea())
        .navigationTitle("Licenses")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var backgroundGradient: some View {
        LinearGradient(
            colors: [DesignTokens.Palette.canvas, DesignTokens.Palette.canvasSunken],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    private var introCard: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Space.sm) {
            Text("Built with the help of these open-source projects.")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(DesignTokens.Palette.ink)
            Text("Each entry shows what the component is and how RoadSense NS uses it.")
                .font(.system(size: 13))
                .foregroundStyle(DesignTokens.Palette.inkMuted)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(DesignTokens.Space.lg)
        .background(
            RoundedRectangle(cornerRadius: DesignTokens.Radius.md, style: .continuous)
                .fill(DesignTokens.Palette.surface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: DesignTokens.Radius.md, style: .continuous)
                .strokeBorder(DesignTokens.Palette.border, lineWidth: 1)
        )
    }

    private func licenseCard(_ license: License) -> some View {
        VStack(alignment: .leading, spacing: DesignTokens.Space.sm) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(license.name)
                        .font(.system(size: 16, weight: .bold, design: .rounded))
                        .foregroundStyle(DesignTokens.Palette.ink)
                    Text(license.licenseName)
                        .font(.system(size: 12, weight: .semibold))
                        .tracking(0.5)
                        .foregroundStyle(DesignTokens.Palette.inkMuted)
                }
                Spacer()
                if let url = license.url {
                    Link(destination: url) {
                        Image(systemName: "arrow.up.forward.square")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(DesignTokens.Palette.deep)
                    }
                    .accessibilityLabel("Open project page")
                }
            }
            Text(license.excerpt)
                .font(.system(size: 14))
                .foregroundStyle(DesignTokens.Palette.inkMuted)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(DesignTokens.Space.lg)
        .background(
            RoundedRectangle(cornerRadius: DesignTokens.Radius.md, style: .continuous)
                .fill(DesignTokens.Palette.surface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: DesignTokens.Radius.md, style: .continuous)
                .strokeBorder(DesignTokens.Palette.border, lineWidth: 1)
        )
    }
}

struct License: Identifiable {
    let id = UUID()
    let name: String
    let url: URL?
    let licenseName: String
    let excerpt: String
}

#Preview("Licenses") {
    NavigationStack {
        LicensesView()
    }
}
