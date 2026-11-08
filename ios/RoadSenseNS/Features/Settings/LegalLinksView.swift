import SwiftUI

/// Privacy Policy, Terms of Use and Support links. Shown in Settings → About
/// and on the onboarding permission screen, so the policy is reachable
/// before any location permission is requested.
struct LegalLinksView: View {
    enum Style {
        case rows
        case inline
    }

    var style: Style = .rows

    var body: some View {
        switch style {
        case .rows:
            VStack(alignment: .leading, spacing: DesignTokens.Space.sm) {
                ForEach(AppLinks.legalAndSupport, id: \.url) { link in
                    Link(destination: link.url) {
                        HStack {
                            Text(link.title)
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(DesignTokens.Palette.deep)
                            Spacer()
                            Image(systemName: "arrow.up.right")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(DesignTokens.Palette.inkMuted)
                        }
                        .padding(.horizontal, DesignTokens.Space.md)
                        .padding(.vertical, DesignTokens.Space.sm)
                        .background(
                            RoundedRectangle(cornerRadius: DesignTokens.Radius.sm, style: .continuous)
                                .fill(DesignTokens.Palette.canvasSunken)
                        )
                    }
                    .accessibilityIdentifier(Self.accessibilityIdentifier(for: link.title))
                    .accessibilityHint("Opens in Safari.")
                }
            }
        case .inline:
            // Falls back to a column at large Dynamic Type sizes.
            ViewThatFits(in: .horizontal) {
                HStack(spacing: DesignTokens.Space.md) { inlineLinks }
                VStack(spacing: DesignTokens.Space.xs) { inlineLinks }
            }
            .frame(maxWidth: .infinity)
        }
    }

    private var inlineLinks: some View {
        ForEach(AppLinks.legalAndSupport, id: \.url) { link in
            Link(link.title, destination: link.url)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(DesignTokens.Palette.deep)
                .accessibilityIdentifier(Self.accessibilityIdentifier(for: link.title))
        }
    }

    static func accessibilityIdentifier(for title: String) -> String {
        "legal." + title.lowercased().replacingOccurrences(of: " ", with: "-")
    }
}
