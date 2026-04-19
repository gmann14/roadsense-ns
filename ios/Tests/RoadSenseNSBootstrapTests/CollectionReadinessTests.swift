import Testing

@testable import RoadSenseNSBootstrap

@Suite("Collection readiness")
struct CollectionReadinessTests {
    @Test("first launch requires the permission flow")
    func firstLaunchRequiresPermissionFlow() {
        let readiness = CollectionReadiness.evaluate(
            PermissionSnapshot(
                location: .notDetermined,
                motion: .notDetermined,
                privacyZones: .pending
            )
        )

        #expect(readiness.stage == .permissionsRequired)
        #expect(readiness.canStartPassiveCollection == false)
        #expect(readiness.backgroundCollection == .unavailable)
    }

    @Test("denied permissions route to help state")
    func deniedPermissionsRouteToHelpState() {
        let readiness = CollectionReadiness.evaluate(
            PermissionSnapshot(
                location: .denied,
                motion: .authorized,
                privacyZones: .configured
            )
        )

        #expect(readiness.stage == .permissionHelp)
        #expect(readiness.canStartPassiveCollection == false)
    }

    @Test("privacy zone decision is mandatory before collection")
    func privacyZoneDecisionIsMandatoryBeforeCollection() {
        let readiness = CollectionReadiness.evaluate(
            PermissionSnapshot(
                location: .whenInUse,
                motion: .authorized,
                privacyZones: .pending
            )
        )

        #expect(readiness.stage == .privacyZonesRequired)
        #expect(readiness.canStartPassiveCollection == false)
        #expect(readiness.backgroundCollection == .upgradeRequired)
    }

    @Test("configured privacy zones unlock collection")
    func configuredPrivacyZonesUnlockCollection() {
        let readiness = CollectionReadiness.evaluate(
            PermissionSnapshot(
                location: .whenInUse,
                motion: .authorized,
                privacyZones: .configured
            )
        )

        #expect(readiness.stage == .ready)
        #expect(readiness.canStartPassiveCollection)
        #expect(readiness.backgroundCollection == .upgradeRequired)
    }

    @Test("skip warning still unlocks collection but keeps risk visible")
    func skipWarningStillUnlocksCollection() {
        let readiness = CollectionReadiness.evaluate(
            PermissionSnapshot(
                location: .always,
                motion: .authorized,
                privacyZones: .skippedWithWarning
            )
        )

        #expect(readiness.stage == .ready)
        #expect(readiness.canStartPassiveCollection)
        #expect(readiness.showsPrivacyRiskWarning)
        #expect(readiness.backgroundCollection == .enabled)
    }
}
