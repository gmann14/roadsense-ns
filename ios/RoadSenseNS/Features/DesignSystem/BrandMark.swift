import SwiftUI

/// RoadSense NS brand mark.
///
/// A `road.lanes` SF Symbol sitting inside a deep-teal disc with the brand
/// signal color as the road tint. Per user preference 2026-04-25, we keep
/// the road glyph rather than a custom canvas mark — it reads as "road" at a
/// glance, which is the whole point.
///
/// Usage: replaces inline `Image(systemName: "road.lanes")` constructions across
/// the app (onboarding header, stats medallion, top-bar brand chip, App Store
/// icon). Centralized so future logo work updates one file.
///
/// Reference: `docs/reviews/2026-04-24-design-audit.md` §1.3 (custom mark
/// reverted in §14 implementation status).
struct BrandMark: View {
    let size: CGFloat

    /// Whether the disc is filled with the deep teal brand color or rendered
    /// against a custom tinted background. `.solid` is the default.
    let style: Style

    enum Style {
        case solid
        case onTinted(Color)
    }

    init(size: CGFloat, style: Style = .solid) {
        self.size = size
        self.style = style
    }

    var body: some View {
        ZStack {
            Circle()
                .fill(discColor)

            Image(systemName: "road.lanes")
                .font(.system(size: size * 0.46, weight: .semibold))
                .foregroundStyle(DesignTokens.Palette.signal)
                .accessibilityHidden(true)
        }
        .frame(width: size, height: size)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("RoadSense NS")
    }

    private var discColor: Color {
        switch style {
        case .solid: return DesignTokens.Palette.deep
        case .onTinted(let color): return color
        }
    }
}

#Preview("Brand mark — solid") {
    HStack(spacing: 24) {
        BrandMark(size: 28)
        BrandMark(size: 48)
        BrandMark(size: 84)
        BrandMark(size: 128)
    }
    .padding()
    .background(DesignTokens.Palette.canvas)
}

#Preview("Brand mark — on tint") {
    HStack(spacing: 24) {
        BrandMark(size: 48, style: .onTinted(DesignTokens.Palette.deep.opacity(0.12)))
        BrandMark(size: 48, style: .onTinted(DesignTokens.Palette.signal.opacity(0.18)))
    }
    .padding()
    .background(DesignTokens.Palette.canvas)
}
