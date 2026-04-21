import Testing

@testable import RoadSenseNSBootstrap

struct BackgroundCollectionPolicyTests {
    @Test
    func enablesBackgroundLocationWithAlwaysLocation() {
        let decision = BackgroundCollectionPolicy.evaluate(
            PermissionSnapshot(
                location: .always,
                motion: .authorized,
                privacyZones: .configured
            )
        )

        #expect(decision.shouldEnableBackgroundLocation)
        #expect(decision.shouldRegisterSignificantLocationBootstrap)
        #expect(!decision.shouldPromptForAlwaysUpgrade)
    }

    @Test
    func promptsForAlwaysUpgradeDuringForegroundOnlyCollection() {
        let decision = BackgroundCollectionPolicy.evaluate(
            PermissionSnapshot(
                location: .whenInUse,
                motion: .authorized,
                privacyZones: .configured
            )
        )

        #expect(!decision.shouldEnableBackgroundLocation)
        #expect(!decision.shouldRegisterSignificantLocationBootstrap)
        #expect(decision.shouldPromptForAlwaysUpgrade)
    }

    @Test
    func keepsBackgroundOnWhenPrivacyZonesAreStillPending() {
        let decision = BackgroundCollectionPolicy.evaluate(
            PermissionSnapshot(
                location: .always,
                motion: .authorized,
                privacyZones: .pending
            )
        )

        #expect(decision.shouldEnableBackgroundLocation)
        #expect(decision.shouldRegisterSignificantLocationBootstrap)
        #expect(!decision.shouldPromptForAlwaysUpgrade)
    }
}
