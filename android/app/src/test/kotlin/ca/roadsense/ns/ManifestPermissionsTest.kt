package ca.roadsense.ns

import org.junit.Test
import java.io.File
import kotlin.test.assertEquals
import kotlin.test.assertTrue

/**
 * Locks the permission list Play reviews. Adding a permission (background
 * location in particular) needs a Data Safety / declaration update in
 * docs/implementation/15-google-play-readiness.md first, so this test has to
 * be changed on purpose.
 */
class ManifestPermissionsTest {
    private val manifest = File("src/main/AndroidManifest.xml").readText()

    private val declared: Set<String> =
        Regex("""<uses-permission\s+android:name="([^"]+)"""")
            .findAll(manifest)
            .map { it.groupValues[1] }
            .toSet()

    @Test
    fun `declares exactly the permissions the shipped features use`() {
        assertEquals(
            setOf(
                "android.permission.INTERNET",
                "android.permission.ACCESS_NETWORK_STATE",
                "android.permission.ACCESS_FINE_LOCATION",
                "android.permission.ACCESS_COARSE_LOCATION",
                "android.permission.POST_NOTIFICATIONS",
                "android.permission.FOREGROUND_SERVICE",
                "android.permission.FOREGROUND_SERVICE_LOCATION",
            ),
            declared,
        )
    }

    @Test
    fun `collection service is a location foreground service`() {
        assertTrue(
            Regex("""android:name="\.collection\.CollectionService"[\s\S]*?android:foregroundServiceType="location"""")
                .containsMatchIn(manifest),
        )
    }
}
