package ca.roadsense.ns.ui.map

import android.annotation.SuppressLint
import android.webkit.WebSettings
import android.webkit.WebView
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.unit.dp
import androidx.compose.ui.viewinterop.AndroidView
import ca.roadsense.ns.BuildConfig
import ca.roadsense.ns.RoadSenseContainer
import ca.roadsense.ns.api.Endpoints

/**
 * Compose host for the road-quality map shell.
 *
 * Two render paths, picked at composition time:
 *   - **Native Mapbox** — [MapboxBridge.createMapView] inflates a real
 *     `MapView` and wires the same vector-tile source iOS uses. Compiled in
 *     when the project synced with `MAPBOX_DOWNLOADS_TOKEN` set (see
 *     `android/settings.gradle.kts`); the no-Mapbox build sees only the
 *     `MapboxBridge` stub, which reports `isAvailable = false`.
 *   - **WebView fallback** — points at `https://roadsense.ca` so the in-app
 *     preview still shows the public map on CI/public-clone builds that
 *     have not provisioned the Mapbox SDK. Production builds always take
 *     the native path once the token is provisioned and a real
 *     `MAPBOX_ACCESS_TOKEN` is configured for the environment.
 */
@Composable
fun MapHost(modifier: Modifier = Modifier) {
    val context = LocalContext.current
    val container = RoadSenseContainer.from(context)
    val endpoints = Endpoints(container.config)
    val accessToken = container.config.mapboxAccessToken
    val useNativeMapbox = BuildConfig.MAPBOX_AVAILABLE &&
        MapboxBridge.isAvailable &&
        accessToken.startsWith("pk.")

    Box(modifier = modifier) {
        AndroidView(
            modifier = Modifier
                .fillMaxWidth()
                .height(280.dp),
            factory = { ctx ->
                if (useNativeMapbox) {
                    runCatching {
                        MapboxBridge.createMapView(
                            ctx,
                            MapboxConfig(
                                tileTemplateURL = endpoints.tileTemplateURLString,
                                accessToken = accessToken,
                            ),
                        )
                    }.getOrElse { fallbackWebView(ctx, endpoints) }
                } else {
                    fallbackWebView(ctx, endpoints)
                }
            },
        )

        // Mapbox terms require attribution when the SDK renders, and we keep
        // the same plate in the WebView path so the visual layout matches
        // whichever renderer is active.
        Text(
            text = "© Mapbox © OpenStreetMap",
            modifier = Modifier
                .align(Alignment.BottomEnd)
                .padding(end = 6.dp, bottom = 6.dp),
            style = MaterialTheme.typography.labelSmall,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
        )
    }
}

@SuppressLint("SetJavaScriptEnabled")
private fun fallbackWebView(
    context: android.content.Context,
    endpoints: Endpoints,
): WebView {
    val webView = WebView(context)
    val settings: WebSettings = webView.settings
    settings.javaScriptEnabled = true
    settings.domStorageEnabled = true
    settings.cacheMode = WebSettings.LOAD_DEFAULT
    val envQuery = when (endpoints.config.environment.name) {
        "STAGING" -> "?staging"
        "LOCAL" -> "?local"
        else -> ""
    }
    webView.loadUrl("https://roadsense.ca/$envQuery")
    return webView
}
