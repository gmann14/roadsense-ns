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
 * Two render paths:
 *   - **Mapbox path** — used when the build was assembled with the Mapbox
 *     Maps SDK on the classpath (controlled by `MAPBOX_AVAILABLE` in
 *     [BuildConfig], driven by `MAPBOX_DOWNLOADS_TOKEN` at sync time).
 *     Loaded reflectively so the project still compiles on a public CI
 *     runner without the private Maven token.
 *   - **WebView fallback** — used in the public/CI build flavor: shows the
 *     same `https://roadsense.ca` map iOS already links to, pointed at the
 *     configured tile endpoint via URL flag so the in-app preview matches
 *     the user's environment.
 */
@Composable
fun MapHost(modifier: Modifier = Modifier) {
    val context = LocalContext.current
    val container = RoadSenseContainer.from(context)
    val endpoints = Endpoints(container.config)
    val mapboxAvailable = BuildConfig.MAPBOX_AVAILABLE && hasMapboxRuntime()

    Box(modifier = modifier) {
        AndroidView(
            modifier = Modifier
                .fillMaxWidth()
                .height(280.dp),
            factory = { ctx ->
                if (mapboxAvailable) {
                    runCatching { reflectiveMapboxView(ctx) }
                        .getOrElse { fallbackWebView(ctx, endpoints) }
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

private fun hasMapboxRuntime(): Boolean = runCatching {
    Class.forName("com.mapbox.maps.MapView")
}.isSuccess

private fun reflectiveMapboxView(context: android.content.Context): android.view.View {
    val mapViewClass = Class.forName("com.mapbox.maps.MapView")
    return mapViewClass.getConstructor(android.content.Context::class.java)
        .newInstance(context) as android.view.View
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
