package ca.roadsense.ns.ui.map

import android.content.Context
import android.view.View

/**
 * No-Mapbox build of the bridge — used whenever the project syncs without
 * the private `MAPBOX_DOWNLOADS_TOKEN`. Reports `isAvailable = false` so the
 * Compose `MapHost` falls back to the public-web-map WebView.
 *
 * `createMapView` is never called in this build path (MapHost gates on
 * `isAvailable`), but we keep the implementation present so accidental calls
 * fail loudly rather than silently rendering a blank surface.
 */
object MapboxBridge {
    const val isAvailable: Boolean = false

    fun createMapView(context: Context, config: MapboxConfig): View {
        throw IllegalStateException(
            "MapboxBridge.createMapView called in the no-Mapbox build flavor. " +
                "Provision MAPBOX_DOWNLOADS_TOKEN at sync time to enable the " +
                "native Mapbox path."
        )
    }
}
