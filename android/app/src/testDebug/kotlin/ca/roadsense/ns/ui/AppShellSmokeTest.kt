package ca.roadsense.ns.ui

import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.onNodeWithText
import ca.roadsense.ns.api.AppEnvironment
import ca.roadsense.ns.permissions.PermissionState
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config

/**
 * Smoke test for the production Compose shell. Two goals:
 *  - lock down that AppShell composes with a realistic [HomeState] without
 *    crashing (saves us from regressing during refactors of the manual
 *    `RoadSenseContainer` wiring)
 *  - exercise the Stats + Settings tabs, which are the screens least
 *    coupled to the live MapHost / RoadSenseContainer / Room stack
 *
 * The Map tab is intentionally *not* selected because `MapHost` calls
 * `RoadSenseContainer.from(context)`, which builds a real Room database
 * on first access. That's covered by `RoadSenseDatabaseTest` already; the
 * smoke here is about the Compose shell, not the DB.
 *
 * Runs on Robolectric so CI doesn't need an emulator.
 *
 * Source-set note: this file lives under `src/testDebug/` rather than the
 * default `src/test/`. `createComposeRule()` needs the `ComponentActivity`
 * declaration provided by `androidx.compose.ui:ui-test-manifest`, which AGP
 * only merges into debug variants. Putting the smoke under `testDebug`
 * keeps `testStaging*ReleaseUnitTest` clean of the missing-activity error
 * without sprinkling `Assume` skips through the test body.
 */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [33])
class AppShellSmokeTest {

    @get:Rule val composeRule = createComposeRule()

    @Test
    fun statsTabRendersWithoutTouchingTheMapHost() {
        val state = sampleState()
        composeRule.setContent {
            AppShell(
                state = state,
                selectedTab = BottomTab.Stats,
                onSelectTab = {},
                onRequestForegroundPermissions = {},
                onRequestBackgroundPermission = {},
                onStart = {},
                onStop = {},
                onUploadNow = {},
                onReportPothole = {},
                onUndoPothole = {},
                onSubmitFeedback = { _, _, _, _ -> },
                onDeleteLocalData = {},
                onClearError = {},
            )
        }

        // Stats screen labels — these are the only strings that should
        // appear when the Stats tab is selected. If a future refactor moves
        // them into the Map screen, the smoke catches it.
        composeRule.onNodeWithText("Your contributions").assertIsDisplayed()
        composeRule.onNodeWithText("Local pending").assertIsDisplayed()
        // The total drives row carries the value verbatim.
        composeRule.onNodeWithText("12").assertIsDisplayed()
    }

    @Test
    fun settingsTabExposesDeleteLocalDataControl() {
        val state = sampleState()
        composeRule.setContent {
            AppShell(
                state = state,
                selectedTab = BottomTab.Settings,
                onSelectTab = {},
                onRequestForegroundPermissions = {},
                onRequestBackgroundPermission = {},
                onStart = {},
                onStop = {},
                onUploadNow = {},
                onReportPothole = {},
                onUndoPothole = {},
                onSubmitFeedback = { _, _, _, _ -> },
                onDeleteLocalData = {},
                onClearError = {},
            )
        }

        // The destructive control is the most policy-loaded button in
        // the app. If it ever silently disappears, the Delete local data
        // privacy promise breaks before anyone notices. We use assertExists
        // (not assertIsDisplayed) because the Settings tab is a vertical
        // scroller and the destructive control + feedback card live below
        // the Robolectric default viewport.
        composeRule.onNodeWithText("Permissions").assertIsDisplayed()
        composeRule.onNodeWithText("Send feedback").assertExists()
        composeRule.onNodeWithText("Delete all local data").assertExists()
    }

    private fun sampleState() = HomeState(
        isRecording = false,
        pendingReadings = 4,
        pendingPotholeActions = 1,
        pendingFeedback = 0,
        totalDrives = 12,
        totalPotholesReported = 3,
        totalUploadedReadings = 1287,
        lastLocation = LocationSnapshot(
            latitude = 44.6488,
            longitude = -63.5752,
            accuracyMeters = 6.5,
            timestampMillis = 0L,
        ),
        permissions = PermissionState(
            fineLocation = true,
            backgroundLocation = false,
            activityRecognition = true,
            notifications = true,
            camera = false,
        ),
        environment = AppEnvironment.STAGING,
        appVersion = "0.1.0 (1)",
        privacyZoneCount = 2,
    )
}
