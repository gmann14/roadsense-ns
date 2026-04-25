import Foundation

/// Centralized catalog of all user-facing copy in RoadSense NS.
///
/// Every visible string in the app routes through here. Source of voice:
/// `docs/reviews/2026-04-24-design-audit.md` §1.4 (tone) + §13 (decisions).
///
/// Translation: per `docs/adr/0002-localization-stance.md`, v1 ships English-only.
/// Each string uses `NSLocalizedString` so a future French pass is a translation
/// file (`fr.lproj/Localizable.strings`), not a code change.
///
/// Voice rules:
/// - Confident Canadian civic, quietly proud.
/// - Numbers over qualifiers ("4.2 km" beats "a few km").
/// - User as contributor, not sensor ("You" / "Your" / "we", not "the device").
/// - Failure copy stays warm ("we'll wait") even at the system's worst moment.
enum BrandVoice {

    // MARK: - Onboarding

    enum Onboarding {
        static let missionHook = NSLocalizedString(
            "onboarding.missionHook",
            value: "A shared map of every pothole and rough stretch in Nova Scotia, built by the people who drive them.",
            comment: "One-line product summary at the top of onboarding."
        )

        static let alwaysLocationContract = NSLocalizedString(
            "onboarding.alwaysLocationContract",
            value: "After your first drive, we'll ask for one more permission — that's when it runs on its own, even when you close the app.",
            comment: "Sets the expectation that Always Location is requested after the first drive."
        )

        static let locationPermissionTitle = NSLocalizedString(
            "onboarding.locationPermission.title",
            value: "Location",
            comment: "Tip title above the location permission guidance."
        )

        static let locationPermissionGuidance = NSLocalizedString(
            "onboarding.locationPermission.guidance",
            value: "Tap **Allow While Using App.** We use location to know which roads you drove — nothing else. Allow Once resets every launch and won't work.",
            comment: "Markdown-flavored guidance for the location permission step."
        )

        static let motionPermissionTitle = NSLocalizedString(
            "onboarding.motionPermission.title",
            value: "Motion & Fitness",
            comment: "Tip title above the motion permission guidance."
        )

        static let motionPermissionGuidance = NSLocalizedString(
            "onboarding.motionPermission.guidance",
            value: "Tap **OK on Motion.** This is how we tell driving from walking or cycling. It stays on your phone.",
            comment: "Markdown-flavored guidance for the motion permission step."
        )

        static let cameraSafetyNote = NSLocalizedString(
            "onboarding.cameraSafetyNote",
            value: "You can grab a photo any time, but please not while you're driving.",
            comment: "Safety note about the camera feature shown during onboarding."
        )

        static let readyTitle = NSLocalizedString(
            "onboarding.ready.title",
            value: "Ready to collect.",
            comment: "Title shown when permissions are in place."
        )

        static let readySubtitleDefault = NSLocalizedString(
            "onboarding.ready.subtitle",
            value: "Drive as you normally would. Your home and work are already shielded by default — RoadSense trims likely trip endpoints before upload. You can add more privacy zones later in Settings.",
            comment: "Default subtitle on the Ready stage of onboarding."
        )

        static let continueButton = NSLocalizedString(
            "onboarding.continue",
            value: "Continue",
            comment: "Primary button to advance through onboarding."
        )

        static let finishSetUpButton = NSLocalizedString(
            "onboarding.finishSetUp",
            value: "Finish set-up",
            comment: "Button label that triggers the Always-Location upgrade flow."
        )

        static let stepEyebrowPermissions = NSLocalizedString(
            "onboarding.eyebrow.permissions",
            value: "Step 1 of 2 · Permissions",
            comment: "Eyebrow shown above the title during the permissions step."
        )

        static let stepEyebrowReady = NSLocalizedString(
            "onboarding.eyebrow.ready",
            value: "Step 2 of 2 · Ready",
            comment: "Eyebrow shown above the title once permissions are granted."
        )

        static let permissionsIncompleteTitle = NSLocalizedString(
            "onboarding.permissionsIncomplete.title",
            value: "Permissions are still incomplete.",
            comment: "Title when permissions failed and user needs Settings."
        )

        static let permissionsIncompleteBody = NSLocalizedString(
            "onboarding.permissionsIncomplete.body",
            value: "Open iOS Settings and enable Location + Motion for RoadSense NS. Passive collection stays off until both are granted.",
            comment: "Body when permissions failed and user needs Settings."
        )

        static let refreshStatusButton = NSLocalizedString(
            "onboarding.refreshStatus",
            value: "Refresh status",
            comment: "Button to re-check permission status after returning from Settings."
        )
    }

    // MARK: - Driving (map screen)

    enum Driving {
        static let appName = NSLocalizedString(
            "driving.appName",
            value: "RoadSense",
            comment: "Brand wordmark in the top-left chip on the driving screen."
        )

        static let markPotholeLabel = NSLocalizedString(
            "driving.markPothole.label",
            value: "Pothole",
            comment: "Label under the hero FAB. Verb-implied: tap to mark a pothole."
        )

        static let markPotholeAccessibilityLabel = NSLocalizedString(
            "driving.markPothole.accessibilityLabel",
            value: "Mark pothole",
            comment: "VoiceOver label for the hero FAB."
        )

        static let markPotholeAccessibilityHint = NSLocalizedString(
            "driving.markPothole.accessibilityHint",
            value: "Queues a pothole report using your current location.",
            comment: "VoiceOver hint for the hero FAB."
        )

        static let photoLabel = NSLocalizedString(
            "driving.photo.label",
            value: "Photo",
            comment: "Label under the secondary camera FAB."
        )

        static let photoAccessibilityLabel = NSLocalizedString(
            "driving.photo.accessibilityLabel",
            value: "Add photo",
            comment: "VoiceOver label for the photo FAB."
        )

        static let photoAccessibilityHint = NSLocalizedString(
            "driving.photo.accessibilityHint",
            value: "Opens the camera. Most useful when you're stopped or walking.",
            comment: "VoiceOver hint for the photo FAB."
        )

        static let statsLabel = NSLocalizedString(
            "driving.stats.label",
            value: "Stats",
            comment: "Label under the secondary stats FAB."
        )

        static let statsAccessibilityLabel = NSLocalizedString(
            "driving.stats.accessibilityLabel",
            value: "View your stats",
            comment: "VoiceOver label for the stats FAB."
        )

        static let undoLastMark = NSLocalizedString(
            "driving.undoLastMark",
            value: "Undo last mark",
            comment: "Label on the floating undo chip after marking a pothole."
        )

        static let undoAccessibilityHint = NSLocalizedString(
            "driving.undoLastMark.hint",
            value: "Removes the most recently marked pothole. Available for 5 seconds.",
            comment: "VoiceOver hint for the undo chip."
        )

        static let firstRunTitle = NSLocalizedString(
            "driving.firstRun.title",
            value: "Drive normally.",
            comment: "Empty-state title on the map before the user has any drives."
        )

        static let firstRunBody = NSLocalizedString(
            "driving.firstRun.body",
            value: "Your first road ribbon shows up after the next sync.",
            comment: "Empty-state body on the map before the user has any drives."
        )

        static func recordingActive(kmMapped: Double) -> String {
            let formatted = kmMapped.formatted(.number.precision(.fractionLength(1)))
            let template = NSLocalizedString(
                "driving.recording.active",
                value: "On the record · %@ km so far.",
                comment: "Status line shown while a drive is in progress, with formatted km value."
            )
            return String(format: template, formatted)
        }

        static let recordingWarmup = NSLocalizedString(
            "driving.recording.warmup",
            value: "Warming up…",
            comment: "Status line shown at the very start of a drive before km accumulates."
        )

        static let recordingIdle = NSLocalizedString(
            "driving.recording.idle",
            value: "On the record when you drive.",
            comment: "Status line shown when no drive is in progress."
        )
    }

    // MARK: - Stats

    enum Stats {
        static let yourContributionEyebrow = NSLocalizedString(
            "stats.eyebrow.yourContribution",
            value: "YOUR CONTRIBUTION",
            comment: "Eyebrow above the headline km readout."
        )

        static let thisMonthMappedSubtitle = NSLocalizedString(
            "stats.thisMonthMapped",
            value: "of Nova Scotia mapped this month.",
            comment: "Subtitle under the headline km readout."
        )

        static func communityThisWeek(km: Double, drivers: Int) -> String {
            let kmFormatted = km.formatted(.number.precision(.fractionLength(0)))
            let driversFormatted = drivers.formatted(.number)
            let template = NSLocalizedString(
                "stats.community.thisWeek",
                value: "Plus %@ km from %@ drivers near you.",
                comment: "Community stat line: aggregate km from other drivers."
            )
            return String(format: template, kmFormatted, driversFormatted)
        }

        static let contributionEmpty = NSLocalizedString(
            "stats.contributionEmpty",
            value: "Once you drive, your contribution shows up here.",
            comment: "Empty state shown on stats screen before the first drive."
        )

        static let impactCardTitle = NSLocalizedString(
            "stats.impactCard.title",
            value: "What it affected",
            comment: "Title of the stats card showing pothole moderation outcomes."
        )

        static let communityCardTitle = NSLocalizedString(
            "stats.communityCard.title",
            value: "Community this week",
            comment: "Title of the stats card showing aggregate community contribution."
        )

        static let technicalDetailsDisclosure = NSLocalizedString(
            "stats.technicalDetails.disclosure",
            value: "Technical details",
            comment: "Disclosure label hiding the readings/quality breakdown."
        )

        static let acceptedReadingsLabel = NSLocalizedString(
            "stats.acceptedReadings.label",
            value: "Accepted readings",
            comment: "Label for the count of readings that survived quality filters."
        )

        static let pendingUploadsLabel = NSLocalizedString(
            "stats.pendingUploads.label",
            value: "Pending uploads",
            comment: "Label for the count of readings queued for upload."
        )

        static let privacyFilteredLabel = NSLocalizedString(
            "stats.privacyFiltered.label",
            value: "Privacy-filtered",
            comment: "Label for the count of readings filtered out by privacy rules."
        )

        static let potholesFlaggedLabel = NSLocalizedString(
            "stats.potholesFlagged.label",
            value: "Potholes flagged",
            comment: "Label for the count of potholes the user reported."
        )

        static let potholesFixedLabel = NSLocalizedString(
            "stats.potholesFixed.label",
            value: "Potholes fixed",
            comment: "Label for the count of user-reported potholes that have been resolved."
        )

        static let potholesAwaitingModerationLabel = NSLocalizedString(
            "stats.potholesAwaiting.label",
            value: "Awaiting moderation",
            comment: "Label for user-reported potholes that haven't been moderated yet."
        )
    }

    // MARK: - Settings

    enum Settings {
        static let collectionTitle = NSLocalizedString(
            "settings.collection.title",
            value: "Collection",
            comment: "Title of the collection (on/off) settings card."
        )

        static let collectionSubtitle = NSLocalizedString(
            "settings.collection.subtitle",
            value: "On / off switch. Background use lets RoadSense keep collecting after you leave the app.",
            comment: "Subtitle of the collection settings card."
        )

        static let startCollectionButton = NSLocalizedString(
            "settings.collection.start",
            value: "Start collection",
            comment: "Button to resume passive collection."
        )

        static let stopCollectionButton = NSLocalizedString(
            "settings.collection.stop",
            value: "Stop collection",
            comment: "Button to pause passive collection."
        )

        static let allowInBackgroundButton = NSLocalizedString(
            "settings.collection.allowInBackground",
            value: "Allow in background",
            comment: "Button to request the Always-Location upgrade from Settings."
        )

        static let privacyTitle = NSLocalizedString(
            "settings.privacy.title",
            value: "Privacy",
            comment: "Title of the privacy settings card."
        )

        static let privacySubtitle = NSLocalizedString(
            "settings.privacy.subtitle",
            value: "Optional zones filter readings on-device before upload. Useful for home, work, or anywhere you stop often.",
            comment: "Subtitle of the privacy settings card."
        )

        static let privacyZonesButton = NSLocalizedString(
            "settings.privacy.zonesButton",
            value: "Manage privacy zones",
            comment: "Button that opens the privacy zones editor."
        )

        static let uploadsTitle = NSLocalizedString(
            "settings.uploads.title",
            value: "Uploads",
            comment: "Title of the uploads settings card."
        )

        static let uploadsSubtitle = NSLocalizedString(
            "settings.uploads.subtitle",
            value: "Uploads happen automatically when a network is available.",
            comment: "Subtitle of the uploads settings card."
        )

        static let aboutTitle = NSLocalizedString(
            "settings.about.title",
            value: "About",
            comment: "Title of the About settings card."
        )

        static let aboutBody = NSLocalizedString(
            "settings.about.body",
            value: "RoadSense NS quietly measures road roughness while you drive and uploads only readings that pass quality and privacy filters. Background collection improves continuity and can be turned off any time.",
            comment: "Body of the About settings card."
        )

        static let dataManagementTitle = NSLocalizedString(
            "settings.dataManagement.title",
            value: "Starting fresh",
            comment: "Title of the data deletion settings card. Calmer than the previous 'Data management' framing."
        )

        static let dataManagementSubtitle = NSLocalizedString(
            "settings.dataManagement.subtitle",
            value: "Clears locally stored readings, pothole reports, upload queue, and stats. Your privacy zones stay in place.",
            comment: "Subtitle of the data deletion settings card."
        )

        static let deleteLocalDataButton = NSLocalizedString(
            "settings.dataManagement.deleteButton",
            value: "Delete local contribution data",
            comment: "Button label for the data deletion action."
        )
    }

    // MARK: - Camera

    enum Camera {
        static let captureGuidance = NSLocalizedString(
            "camera.captureGuidance",
            value: "Slow down or pull over first. Daylight works best.",
            comment: "Always-on safety nudge below the camera capture button."
        )

        static let safetyWarningWhileMoving = NSLocalizedString(
            "camera.safetyWarning.whileMoving",
            value: "Looks like you might be driving. Pull over to be safe — we'll wait.",
            comment: "Banner shown at the top of the camera capture view when speed suggests driving."
        )

        static let reviewTitle = NSLocalizedString(
            "camera.review.title",
            value: "Review photo",
            comment: "Title shown after capturing a photo, before submission."
        )

        static let reviewSubtitle = NSLocalizedString(
            "camera.review.subtitle",
            value: "This will help moderators confirm the pothole. Yours stays private.",
            comment: "Subtitle on the photo review screen reinforcing pro-social purpose + privacy."
        )

        static let retakeButton = NSLocalizedString(
            "camera.retake",
            value: "Retake",
            comment: "Button to discard the captured photo and reopen capture."
        )

        static let submitButton = NSLocalizedString(
            "camera.submit",
            value: "Submit",
            comment: "Button to upload the captured photo for moderation."
        )

        static let cancelButton = NSLocalizedString(
            "camera.cancel",
            value: "Cancel",
            comment: "Button to dismiss the camera flow without submitting."
        )

        static let accessOffTitle = NSLocalizedString(
            "camera.accessOff.title",
            value: "Camera access is off",
            comment: "Title shown when iOS camera permission is denied."
        )

        static let accessOffBody = NSLocalizedString(
            "camera.accessOff.body",
            value: "Allow camera access in Settings to submit pothole photos.",
            comment: "Body shown when iOS camera permission is denied."
        )

        static let openSettingsButton = NSLocalizedString(
            "camera.openSettings",
            value: "Open Settings",
            comment: "Button to deep-link into iOS Settings."
        )
    }

    // MARK: - NeedsAttentionPill states (§13.5)

    enum Attention {
        static let alwaysLocationCallToAction = NSLocalizedString(
            "attention.alwaysLocation",
            value: "Set it and forget it →",
            comment: "Pill copy when Always-Location upgrade is needed."
        )

        static let locationDeniedCallToAction = NSLocalizedString(
            "attention.locationDenied",
            value: "Location is off →",
            comment: "Pill copy when location permission is denied."
        )

        static let motionDeniedCallToAction = NSLocalizedString(
            "attention.motionDenied",
            value: "Motion is off — accuracy reduced →",
            comment: "Pill copy when motion permission is denied."
        )

        static let mapLoadFailedCallToAction = NSLocalizedString(
            "attention.mapLoadFailed",
            value: "Map didn't load — retry",
            comment: "Pill copy when Mapbox tiles failed to load."
        )

        static let pausedCallToAction = NSLocalizedString(
            "attention.paused",
            value: "Paused — tap to resume",
            comment: "Pill copy when the user has paused passive collection."
        )

        static let failedUploadsCallToAction = NSLocalizedString(
            "attention.failedUploads",
            value: "Some uploads need help →",
            comment: "Pill copy when there are failed uploads requiring user action."
        )

        static let thermalPausedCallToAction = NSLocalizedString(
            "attention.thermalPaused",
            value: "Phone too hot — paused",
            comment: "Pill copy when collection is paused due to thermal state."
        )

        static let offlineCallToAction = NSLocalizedString(
            "attention.offline",
            value: "Offline — uploads queued",
            comment: "Pill copy when no network is available; uploads will resume on reconnect."
        )
    }

    // MARK: - Failure feedback (toast/banner copy)

    enum Failures {
        static let needFreshGPSTitle = NSLocalizedString(
            "failure.needFreshGPS.title",
            value: "Need a fresh GPS fix",
            comment: "Failure title when location is stale or unavailable."
        )

        static let needFreshGPSBody = NSLocalizedString(
            "failure.needFreshGPS.body",
            value: "Keep the app open for a moment, then try again.",
            comment: "Failure body when location is stale or unavailable."
        )

        static let insidePrivacyZoneTitle = NSLocalizedString(
            "failure.insidePrivacyZone.title",
            value: "Inside a privacy zone",
            comment: "Failure title when an action is rejected because it's inside a privacy zone."
        )

        static let insidePrivacyZoneBody = NSLocalizedString(
            "failure.insidePrivacyZone.body",
            value: "RoadSense will not report from an excluded area. That's working as intended.",
            comment: "Failure body when an action is rejected because of a privacy zone."
        )

        static let outsideCoverageTitle = NSLocalizedString(
            "failure.outsideCoverage.title",
            value: "Outside coverage area",
            comment: "Failure title when location is outside Nova Scotia."
        )

        static let outsideCoverageBody = NSLocalizedString(
            "failure.outsideCoverage.body",
            value: "RoadSense currently works only within Nova Scotia. We'll grow with the network.",
            comment: "Failure body when location is outside the coverage region."
        )

        static let queuedSuccessTitle = NSLocalizedString(
            "failure.queuedSuccess.title",
            value: "Pothole marked",
            comment: "Success title after a pothole mark is queued (it's not a failure but lives with feedback copy)."
        )

        static let queuedSuccessBody = NSLocalizedString(
            "failure.queuedSuccess.body",
            value: "Sending in 5 seconds — tap Undo to cancel.",
            comment: "Success body after a pothole mark is queued."
        )

        static let photoQueuedTitle = NSLocalizedString(
            "failure.photoQueued.title",
            value: "Photo queued",
            comment: "Success title after a photo is queued for upload."
        )

        static let photoQueuedBody = NSLocalizedString(
            "failure.photoQueued.body",
            value: "We'll upload it and send it to moderation automatically.",
            comment: "Success body after a photo is queued for upload."
        )
    }

    // MARK: - Notifications (local notification copy)

    enum Notifications {
        static let idleResumeTitle = NSLocalizedString(
            "notification.idleResume.title",
            value: "RoadSense isn't collecting",
            comment: "Notification title sent after 48h of no data collection."
        )

        static let idleResumeBody = NSLocalizedString(
            "notification.idleResume.body",
            value: "Tap to resume.",
            comment: "Notification body for the idle-resume reminder."
        )

        static let thermalPauseTitle = NSLocalizedString(
            "notification.thermalPause.title",
            value: "Phone is too hot",
            comment: "Notification title when collection auto-pauses due to thermal state."
        )

        static let thermalPauseBody = NSLocalizedString(
            "notification.thermalPause.body",
            value: "Collection paused. It will resume when your device cools down.",
            comment: "Notification body for the thermal-pause notification."
        )
    }
}
