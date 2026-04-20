import SwiftUI

/// Canonical design tokens. Source of truth lives in `docs/design-tokens.md`.
/// Never introduce new hex literals in feature code — extend the enums below instead.
enum DesignTokens {

    // MARK: - Color

    enum Palette {
        // Adaptive surface / ink
        static let canvas = Color(light: 0xF6F1E8, dark: 0x0B1419)
        static let canvasSunken = Color(light: 0xECE5D5, dark: 0x060D11)
        static let surface = Color(light: 0xFFFCF5, dark: 0x132129)
        static let surfaceElevated = Color(light: 0xFFFFFF, dark: 0x1B2B34)

        static let ink = Color(light: 0x0F1E26, dark: 0xEEF2F4)
        static let inkMuted = Color(light: 0x55707D, dark: 0x90A4AE)
        static let inkFaint = Color(light: 0x8FA3AB, dark: 0x617680)

        static let border = Color(light: 0x0F1E26, dark: 0xEEF2F4).opacity(0.10)
        static let borderStrong = Color(light: 0x0F1E26, dark: 0xEEF2F4).opacity(0.18)

        // Brand
        static let deep = Color(hex: 0x0E3B4A)
        static let deepInk = Color(hex: 0x07222C)
        static let signal = Color(hex: 0xE9A23B)
        static let signalSoft = Color(hex: 0xF7DFB1)

        // Roughness ramp (unified with web)
        static let smooth = Color(hex: 0x2F8F6D)
        static let fair = Color(hex: 0xE2B341)
        static let rough = Color(hex: 0xD97636)
        static let veryRough = Color(hex: 0xC04242)
        static let unpaved = Color(hex: 0x8A9AA2)

        // Semantic
        static let success = Color(hex: 0x2F8F6D)
        static let warning = Color(hex: 0xD97636)
        static let danger = Color(hex: 0xC04242)
    }

    // MARK: - Space

    enum Space {
        static let xxs: CGFloat = 4
        static let xs: CGFloat = 8
        static let sm: CGFloat = 12
        static let md: CGFloat = 16
        static let lg: CGFloat = 20
        static let xl: CGFloat = 24
        static let xxl: CGFloat = 32
        static let xxxl: CGFloat = 48
        static let huge: CGFloat = 64
    }

    // MARK: - Radius

    enum Radius {
        static let xs: CGFloat = 8
        static let sm: CGFloat = 14
        static let md: CGFloat = 20
        static let lg: CGFloat = 28
        static let pill: CGFloat = 999
    }

    // MARK: - Motion

    enum Motion {
        static let standard: Animation = .easeOut(duration: 0.22)
        static let enter: Animation = .timingCurve(0.16, 1, 0.3, 1, duration: 0.36)
        static let map: Animation = .linear(duration: 0.6)
        static let celebrate: Animation = .interpolatingSpring(stiffness: 180, damping: 16)
    }

    // MARK: - Type

    enum TypeFace {
        static func display(size: CGFloat, weight: Font.Weight = .bold) -> Font {
            .system(size: size, weight: weight, design: .rounded)
        }

        static func number(size: CGFloat, weight: Font.Weight = .bold) -> Font {
            .system(size: size, weight: weight, design: .rounded).monospacedDigit()
        }
    }

    enum TypeStyle {
        static let display = TypeFace.display(size: 40, weight: .bold)
        static let title = TypeFace.display(size: 28, weight: .bold)
        static let headline = Font.system(size: 20, weight: .semibold, design: .default)
        static let body = Font.system(size: 16, weight: .regular)
        static let callout = Font.system(size: 15, weight: .medium)
        static let caption = Font.system(size: 13, weight: .medium)
        static let eyebrow = Font.system(size: 11, weight: .bold).width(.expanded)
        static let numberLg = TypeFace.number(size: 48, weight: .bold)
        static let numberMd = TypeFace.number(size: 22, weight: .semibold)
    }
}

// MARK: - Ramp helpers

extension DesignTokens {
    /// Resolve a roughness category string (matches backend enum) to its ramp color.
    static func rampColor(for category: String) -> Color {
        switch category {
        case "smooth":      return Palette.smooth
        case "fair":        return Palette.fair
        case "rough":       return Palette.rough
        case "very_rough":  return Palette.veryRough
        case "unpaved":     return Palette.unpaved
        default:            return Palette.inkFaint
        }
    }
}

// MARK: - Color conveniences

extension Color {
    /// Solid color from a hex literal. Preferred over `Color(roadsenseHex:)`.
    init(hex: UInt32, alpha: Double = 1) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255.0,
            green: Double((hex >> 8) & 0xFF) / 255.0,
            blue: Double(hex & 0xFF) / 255.0,
            opacity: alpha
        )
    }

    /// Dynamic color that adapts to light / dark.
    init(light: UInt32, dark: UInt32) {
        self.init(uiColor: UIColor { trait in
            trait.userInterfaceStyle == .dark
                ? UIColor(hex: dark)
                : UIColor(hex: light)
        })
    }
}

extension UIColor {
    convenience init(hex: UInt32, alpha: CGFloat = 1) {
        self.init(
            red: CGFloat((hex >> 16) & 0xFF) / 255.0,
            green: CGFloat((hex >> 8) & 0xFF) / 255.0,
            blue: CGFloat(hex & 0xFF) / 255.0,
            alpha: alpha
        )
    }
}

// MARK: - Legacy shim

/// Temporary bridge so any remaining `Color(roadsenseHex: ...)` call sites keep compiling
/// while we migrate to `DesignTokens.Palette.*`. Do not introduce new call sites.
@available(*, deprecated, message: "Use DesignTokens.Palette.* instead of hex literals.")
extension Color {
    init(roadsenseHex hex: UInt32) {
        self.init(hex: hex)
    }
}
