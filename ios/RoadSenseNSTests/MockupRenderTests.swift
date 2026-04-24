import SwiftUI
import UIKit
import XCTest
@testable import RoadSense_NS

/// Renders each `MapScreenRedesignPreview.MockScenario` to a PNG under
/// `docs/reviews/assets/` using `ImageRenderer`. Gated on the `MOCKUP_RENDER=1`
/// environment variable so it doesn't run during normal test invocations.
///
/// Run with:
/// ```
/// MOCKUP_RENDER=1 xcodebuild test \
///   -project ios/RoadSenseNS.xcodeproj \
///   -scheme RoadSenseNS \
///   -destination 'platform=iOS Simulator,name=iPhone 15 Pro' \
///   -only-testing:RoadSenseNSTests/MockupRenderTests/testRenderMockups
/// ```
@MainActor
final class MockupRenderTests: XCTestCase {
    func testRenderMockups() throws {
        guard ProcessInfo.processInfo.environment["MOCKUP_RENDER"] == "1" else {
            throw XCTSkip("Set MOCKUP_RENDER=1 to render mockups.")
        }

        let outputURL = URL(
            fileURLWithPath: "/Users/grahammann/conductor/workspaces/roadsense-ns/lima/docs/reviews/assets",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: outputURL, withIntermediateDirectories: true)

        // iPhone 15 Pro points (logical). Scale ×3 → 1179×2556 px.
        let deviceSize = CGSize(width: 393, height: 852)

        for scenario in MapScreenRedesignPreview.MockScenario.allCases {
            let view = StaticPreview(scenario: scenario)
                .frame(width: deviceSize.width, height: deviceSize.height)

            let renderer = ImageRenderer(content: view)
            renderer.scale = 3.0
            renderer.proposedSize = ProposedViewSize(deviceSize)

            guard let uiImage = renderer.uiImage else {
                XCTFail("Failed to render scenario \(scenario.rawValue)")
                continue
            }

            guard let data = uiImage.pngData() else {
                XCTFail("Failed to encode PNG for scenario \(scenario.rawValue)")
                continue
            }

            let slug = slugify(scenario.rawValue)
            let fileURL = outputURL.appendingPathComponent("mockup-\(slug).png")
            try data.write(to: fileURL)
            print("[MockupRender] Wrote \(fileURL.path) (\(data.count) bytes)")
        }
    }

    private func slugify(_ value: String) -> String {
        let allowed = CharacterSet.lowercaseLetters.union(.decimalDigits).union(CharacterSet(charactersIn: "-"))
        let lowered = value
            .lowercased()
            .replacingOccurrences(of: "·", with: "-")
            .replacingOccurrences(of: " ", with: "-")
        let scalars = lowered.unicodeScalars.map { scalar -> Character in
            allowed.contains(scalar) ? Character(scalar) : "-"
        }
        var result = String(scalars)
        while result.contains("--") {
            result = result.replacingOccurrences(of: "--", with: "-")
        }
        return result.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    }
}
