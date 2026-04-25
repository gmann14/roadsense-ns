import SwiftUI

/// Single source of truth for the "something needs your attention" state shown on
/// the driving screen. Reference: `docs/reviews/2026-04-24-design-audit.md` §13.5.
///
/// Priority — only one pill at a time:
/// 1. Always-Location upgrade required
/// 2. Location permission denied
/// 3. Motion permission denied
/// 4. Map tile load failed
/// 5. Collection paused by user
/// 6. Failed uploads (readings or photos) need attention
/// 7. Thermal pause (auto-resumes)
/// 8. Offline (uploads queued)
enum AttentionState: Equatable {
    case alwaysLocationUpgrade
    case locationDenied
    case motionDenied
    case mapLoadFailed(message: String? = nil)
    case paused
    case failedUploads
    case thermalPaused
    case offline

    var copy: String {
        switch self {
        case .alwaysLocationUpgrade: return BrandVoice.Attention.alwaysLocationCallToAction
        case .locationDenied:        return BrandVoice.Attention.locationDeniedCallToAction
        case .motionDenied:          return BrandVoice.Attention.motionDeniedCallToAction
        case .mapLoadFailed:         return BrandVoice.Attention.mapLoadFailedCallToAction
        case .paused:                return BrandVoice.Attention.pausedCallToAction
        case .failedUploads:         return BrandVoice.Attention.failedUploadsCallToAction
        case .thermalPaused:         return BrandVoice.Attention.thermalPausedCallToAction
        case .offline:               return BrandVoice.Attention.offlineCallToAction
        }
    }

    /// Whether the pill encourages user action. Amber when actionable; muted when
    /// the state will resolve on its own (thermal pause, offline reconnect).
    var isActionable: Bool {
        switch self {
        case .alwaysLocationUpgrade, .locationDenied, .motionDenied,
             .mapLoadFailed, .paused, .failedUploads:
            return true
        case .thermalPaused, .offline:
            return false
        }
    }

    /// Severity → color mapping. Failures use danger; everything else uses signal.
    var severity: Severity {
        switch self {
        case .failedUploads:
            return .failure
        case .alwaysLocationUpgrade, .locationDenied, .motionDenied,
             .mapLoadFailed, .paused, .thermalPaused, .offline:
            return .nudge
        }
    }

    enum Severity {
        case nudge
        case failure
    }

    /// VoiceOver hint per state — what tapping the pill will do.
    var accessibilityHint: String {
        switch self {
        case .alwaysLocationUpgrade: return "Opens the Always-Location upgrade flow."
        case .locationDenied, .motionDenied: return "Opens iOS Settings to fix the permission."
        case .mapLoadFailed: return "Retries loading the map."
        case .paused: return "Resumes passive collection."
        case .failedUploads: return "Opens upload settings to retry or remove failed items."
        case .thermalPaused: return "Collection will resume automatically when the device cools."
        case .offline: return "Uploads will resume when network is available."
        }
    }
}
