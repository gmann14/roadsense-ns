import UIKit

/// Catalog of haptic feedback events — `docs/reviews/2026-04-24-design-audit.md` §13.7.
///
/// Routed through a protocol so tests can verify the right haptic fires for the right event,
/// and so previews/headless contexts can opt out via `NoOpHaptics`.
///
/// Voice rule: haptics are extension of brand voice. Prefer subtle (`.soft`, `.light`) for
/// confirmations; reserve `.medium` for the user's intentional primary action and `.rigid`
/// for nothing. Never fire on background events the user didn't initiate.
protocol HapticsServicing {
    func impact(_ style: HapticImpactStyle)
    func notification(_ feedback: HapticNotificationStyle)
}

enum HapticImpactStyle {
    case light
    case medium
    case soft
    case rigid
}

enum HapticNotificationStyle {
    case success
    case warning
    case error
}

/// Real implementation backed by `UIKit` feedback generators.
/// iOS automatically respects system-wide haptic preferences (e.g., Reduce Haptics);
/// no manual gating needed.
final class UIKitHaptics: HapticsServicing {
    private let impactLight = UIImpactFeedbackGenerator(style: .light)
    private let impactMedium = UIImpactFeedbackGenerator(style: .medium)
    private let impactSoft = UIImpactFeedbackGenerator(style: .soft)
    private let impactRigid = UIImpactFeedbackGenerator(style: .rigid)
    private let notificationGenerator = UINotificationFeedbackGenerator()

    init() {
        impactLight.prepare()
        impactMedium.prepare()
        impactSoft.prepare()
        impactRigid.prepare()
        notificationGenerator.prepare()
    }

    func impact(_ style: HapticImpactStyle) {
        switch style {
        case .light: impactLight.impactOccurred()
        case .medium: impactMedium.impactOccurred()
        case .soft: impactSoft.impactOccurred()
        case .rigid: impactRigid.impactOccurred()
        }
    }

    func notification(_ feedback: HapticNotificationStyle) {
        let kind: UINotificationFeedbackGenerator.FeedbackType = {
            switch feedback {
            case .success: return .success
            case .warning: return .warning
            case .error: return .error
            }
        }()
        notificationGenerator.notificationOccurred(kind)
    }
}

/// Drop-in haptics service that does nothing. Used by previews, harnesses, and the
/// default test container — tests that *want* to assert on haptics swap in `MockHaptics`.
final class NoOpHaptics: HapticsServicing {
    func impact(_ style: HapticImpactStyle) {}
    func notification(_ feedback: HapticNotificationStyle) {}
}
