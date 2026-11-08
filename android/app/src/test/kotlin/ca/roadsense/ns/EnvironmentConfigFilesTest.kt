package ca.roadsense.ns

import org.junit.Test
import java.io.File
import java.net.URI
import java.util.Properties
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue

/**
 * P0-3 (2026-10-18 review): the committed flavor config once pointed the
 * production API, privacy link and WebView at `roadsense.ca`, a domain owned
 * by a third party. These checks read the committed `android/config/` files
 * that `app/build.gradle.kts` turns into `BuildConfig`, so a regression fails
 * the unit-test run instead of shipping.
 */
class EnvironmentConfigFilesTest {
    private val configDir: File = listOf(File("../config"), File("android/config"), File("config"))
        .first { it.resolve("production.env.properties").exists() }

    private fun load(env: String): Properties = Properties().apply {
        configDir.resolve("$env.env.properties").inputStream().use(::load)
    }

    @Test
    fun productionUsesTheProjectApiHostAndKeepsPhotosOff() {
        val props = load("production")
        assertEquals("https://api.nsroadsense.ca", props.getProperty("API_BASE_URL"))
        assertEquals("false", props.getProperty("ENABLE_POTHOLE_PHOTOS"))
    }

    @Test
    fun stagingGoesThroughTheProxyNotTheRawOrigin() {
        val props = load("staging")
        val host = URI(props.getProperty("API_BASE_URL")).host
        assertEquals("api.nsroadsense.ca", host)
        assertFalse(host.endsWith("railway.app"), "staging must not bypass the Cloudflare proxy")
        assertEquals("false", props.getProperty("ENABLE_POTHOLE_PHOTOS"))
    }

    @Test
    fun noCommittedConfigReferencesTheThirdPartyDomain() {
        val thirdParty = Regex("""(^|[^a-z0-9.-])roadsense\.ca\b""", RegexOption.IGNORE_CASE)
        val files = configDir.listFiles { f -> f.name.endsWith(".env.properties") }.orEmpty()
        assertTrue(files.size >= 3, "expected local/staging/production config files in $configDir")
        files.forEach { file ->
            assertFalse(thirdParty.containsMatchIn(file.readText()), "${file.name} references roadsense.ca")
        }
    }
}
