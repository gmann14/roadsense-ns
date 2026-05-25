package ca.roadsense.ns

import androidx.test.core.app.ApplicationProvider
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import org.junit.Test
import org.junit.runner.RunWith
import kotlin.test.assertEquals
import kotlin.test.assertTrue

/**
 * Scaffold instrumentation test that proves the `androidTest/` source set
 * is wired up. Runs on a connected device or emulator:
 *
 *     ./gradlew :app:connectedStagingDebugAndroidTest
 *
 * CI does **not** boot an emulator yet, so this file is local-only. When
 * we add the emulator job (probably via `reactivecircus/android-emulator-runner`
 * once foreground-service + permissions coverage demands it), this file is
 * already on the classpath and additional flows can grow alongside it.
 *
 * Concrete instrumentation tests to add next:
 *  - foreground-service start/stop survives an app-task swipe
 *  - permission deny matrix (fine location, notifications, activity recognition)
 *  - Compose-level: tap "Mark pothole here" then "Undo last report" within 8s
 *
 * Each of those needs UI-thread + Android-runtime coverage that JVM-only
 * Robolectric can't fully reproduce.
 */
@RunWith(AndroidJUnit4::class)
class AppPackageInstrumentationTest {

    @Test
    fun staging_application_id_matches_the_build_flavor() {
        val context = ApplicationProvider.getApplicationContext<android.content.Context>()
        // The staging flavor adds the `.staging` suffix; this catches the
        // case where someone accidentally drops the suffix and uploads a
        // staging build under the production id.
        assertTrue(
            context.packageName.startsWith("ca.roadsense.android"),
            "unexpected applicationId: ${context.packageName}",
        )
    }

    @Test
    fun target_context_is_the_app_under_test() {
        val targetContext = InstrumentationRegistry.getInstrumentation().targetContext
        assertEquals(
            ApplicationProvider.getApplicationContext<android.content.Context>().packageName,
            targetContext.packageName,
        )
    }
}
