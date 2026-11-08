package ca.roadsense.ns.api

import org.junit.jupiter.api.Test
import java.net.URI
import kotlin.test.assertEquals
import kotlin.test.assertTrue

class PublicLinksTest {
    @Test
    fun everyLinkUsesHttpsOnTheProjectDomain() {
        PublicLinks.all.forEach { link ->
            val uri = URI(link)
            assertEquals("https", uri.scheme, link)
            assertEquals("nsroadsense.ca", uri.host, link)
        }
    }

    @Test
    fun linksPointAtTheExpectedPages() {
        assertEquals("https://nsroadsense.ca", PublicLinks.WEB_MAP)
        assertEquals("https://nsroadsense.ca/privacy", PublicLinks.PRIVACY_POLICY)
        assertEquals("https://nsroadsense.ca/terms", PublicLinks.TERMS)
        assertEquals("https://nsroadsense.ca/support", PublicLinks.SUPPORT)
    }

    @Test
    fun photosDefaultOffAndParseFromConfigMap() {
        val base = mapOf(
            "APP_ENV" to "production",
            "API_BASE_URL" to "https://api.nsroadsense.ca",
            "MAPBOX_ACCESS_TOKEN" to "pk.test",
            "SUPABASE_ANON_KEY" to "anon.test",
        )
        assertEquals(false, AppConfig.fromMap(base).enablePotholePhotos)
        assertEquals(false, AppConfig.fromMap(base + ("ENABLE_POTHOLE_PHOTOS" to "false")).enablePotholePhotos)
        assertTrue(AppConfig.fromMap(base + ("ENABLE_POTHOLE_PHOTOS" to "true")).enablePotholePhotos)
        assertEquals(
            "https://api.nsroadsense.ca/functions/v1",
            AppConfig.fromMap(base).functionsBaseURL,
        )
    }
}
