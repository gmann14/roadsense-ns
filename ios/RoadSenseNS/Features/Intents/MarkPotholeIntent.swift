import AppIntents
import Foundation

/// Holds the reporter the intent uses. Set from `RoadSenseNSApp.init`, which
/// runs whenever the system launches the app to perform an intent.
@MainActor
enum ManualPotholeReporterRuntime {
    static var reporter: ManualPotholeReporter?
}

/// Hands-free pothole marking for drivers ("Hey Siri, mark pothole in
/// RoadSense NS"), so nobody has to touch the phone while moving
/// (App Review guideline 1.4.5).
struct MarkPotholeIntent: AppIntent {
    static let title: LocalizedStringResource = "Mark Pothole"
    static let description = IntentDescription(
        "Marks a pothole at your current location. Readings inside your privacy zones are never sent."
    )
    static let openAppWhenRun = false

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        guard let reporter = ManualPotholeReporterRuntime.reporter else {
            return .result(dialog: IntentDialog(stringLiteral: MarkPotholeIntentDialog.unavailable))
        }
        let result = reporter.report()
        return .result(dialog: IntentDialog(stringLiteral: MarkPotholeIntentDialog.text(for: result)))
    }
}

enum MarkPotholeIntentDialog {
    static let unavailable = "RoadSense NS isn't ready yet. Open the app once, then try again."

    static func text(for result: PotholeActionSubmissionResult) -> String {
        switch result {
        case .queued:
            return "Pothole marked at your current location."
        case .unavailableLocation:
            return "RoadSense NS doesn't have a current location fix, so nothing was marked."
        case .insidePrivacyZone:
            return "You're inside a privacy zone, so nothing was marked."
        }
    }
}

struct RoadSenseShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: MarkPotholeIntent(),
            phrases: [
                "Mark pothole in \(.applicationName)",
                "Mark a pothole with \(.applicationName)",
                "Report pothole in \(.applicationName)",
            ],
            shortTitle: "Mark Pothole",
            systemImageName: "exclamationmark.triangle.fill"
        )
    }
}
