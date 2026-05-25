package ca.roadsense.ns.ui.map

import android.content.Context
import android.view.View
import com.mapbox.common.MapboxOptions
import com.mapbox.geojson.Point
import com.mapbox.maps.CameraOptions
import com.mapbox.maps.MapView
import com.mapbox.maps.Style
import com.mapbox.maps.extension.style.expressions.generated.Expression
import com.mapbox.maps.extension.style.layers.generated.circleLayer
import com.mapbox.maps.extension.style.layers.generated.lineLayer
import com.mapbox.maps.extension.style.layers.properties.generated.LineCap
import com.mapbox.maps.extension.style.layers.properties.generated.LineJoin
import com.mapbox.maps.extension.style.sources.generated.vectorSource
import com.mapbox.maps.extension.style.style

/**
 * Real-Mapbox build of the bridge — included only when the project synced
 * with the private `MAPBOX_DOWNLOADS_TOKEN`. The Compose `MapHost` calls into
 * [createMapView] to inflate a native `MapView`, register the same vector
 * tile source iOS uses, and add the road-quality + pothole layers.
 *
 * Source-layer names, ramp colors, and zoom bounds all flow from
 * [RoadQualityStyle] so iOS, web, and Android stay aligned without touching
 * three files for every style tweak.
 */
object MapboxBridge {
    const val isAvailable: Boolean = true

    fun createMapView(context: Context, config: MapboxConfig): View {
        // Mapbox 11.x reads the public access token off MapboxOptions globally.
        // Setting it here is idempotent — the same value is safe to assign on
        // every MapView creation.
        MapboxOptions.accessToken = config.accessToken

        val mapView = MapView(context)
        mapView.mapboxMap.setCamera(
            CameraOptions.Builder()
                .center(Point.fromLngLat(config.initialLng, config.initialLat))
                .zoom(config.initialZoom)
                .bearing(0.0)
                .pitch(0.0)
                .build()
        )

        mapView.mapboxMap.loadStyle(
            style(styleUri = Style.STANDARD) {
                // Segment-aggregate vector source — same MVT endpoint iOS hits.
                +vectorSource(id = RoadQualityStyle.SEGMENT_SOURCE_ID) {
                    tiles(listOf(config.tileTemplateURL))
                    minzoom(RoadQualityStyle.SEGMENT_MIN_ZOOM.toLong())
                    maxzoom(RoadQualityStyle.SEGMENT_MAX_ZOOM.toLong())
                }

                +lineLayer(
                    layerId = RoadQualityStyle.SEGMENT_LAYER_ID,
                    sourceId = RoadQualityStyle.SEGMENT_SOURCE_ID,
                ) {
                    sourceLayer(RoadQualityStyle.SEGMENT_SOURCE_LAYER)
                    lineCap(LineCap.ROUND)
                    lineJoin(LineJoin.ROUND)
                    lineColor(segmentColorExpression())
                    lineOpacity(segmentOpacityExpression())
                    lineWidth(segmentWidthExpression())
                }

                // Potholes layer.
                +vectorSource(id = RoadQualityStyle.POTHOLE_SOURCE_ID) {
                    tiles(listOf(config.tileTemplateURL))
                    minzoom(RoadQualityStyle.POTHOLE_MIN_ZOOM.toLong())
                    maxzoom(RoadQualityStyle.POTHOLE_MAX_ZOOM.toLong())
                }

                +circleLayer(
                    layerId = RoadQualityStyle.POTHOLE_LAYER_ID,
                    sourceId = RoadQualityStyle.POTHOLE_SOURCE_ID,
                ) {
                    sourceLayer(RoadQualityStyle.POTHOLE_SOURCE_LAYER)
                    circleColor(RoadQualityStyle.COLOR_VERY_ROUGH)
                    circleStrokeColor("#FFFFFF")
                    circleStrokeWidth(1.5)
                    circleRadius(potholeRadiusExpression())
                    circleOpacity(0.9)
                }
            }
        )

        return mapView
    }

    /** Matches `RoadQualityMapStyleContent.segmentColorExpression` on iOS. */
    private fun segmentColorExpression(): Expression =
        Expression.fromRaw(
            """
            ["match",
              ["get", "category"],
              "smooth",     "${RoadQualityStyle.COLOR_SMOOTH}",
              "fair",       "${RoadQualityStyle.COLOR_FAIR}",
              "rough",      "${RoadQualityStyle.COLOR_ROUGH}",
              "very_rough", "${RoadQualityStyle.COLOR_VERY_ROUGH}",
              "unpaved",    "${RoadQualityStyle.COLOR_WARNING}",
              "${RoadQualityStyle.COLOR_UNKNOWN}"
            ]
            """.trimIndent()
        )

    /** Matches `RoadQualityMapStyleContent.segmentOpacityExpression` on iOS. */
    private fun segmentOpacityExpression(): Expression =
        Expression.fromRaw(
            """
            ["case",
              ["==", ["get", "confidence"], "low"],    ${RoadQualityStyle.OPACITY_LOW_CONFIDENCE},
              ["==", ["get", "confidence"], "medium"], ${RoadQualityStyle.OPACITY_MEDIUM_CONFIDENCE},
              ${RoadQualityStyle.OPACITY_HIGH_CONFIDENCE}
            ]
            """.trimIndent()
        )

    /** Matches `RoadQualityMapStyleContent.segmentWidthExpression` on iOS. */
    private fun segmentWidthExpression(): Expression =
        Expression.fromRaw(
            """
            ["interpolate", ["linear"], ["zoom"],
              10, 1.5,
              14, 3.0,
              18, 6.0
            ]
            """.trimIndent()
        )

    /** Matches `RoadQualityMapStyleContent.potholeRadiusExpression` on iOS. */
    private fun potholeRadiusExpression(): Expression =
        Expression.fromRaw(
            """
            ["interpolate", ["linear"], ["coalesce", ["get", "magnitude"], 1.0],
              1.0, 3.0,
              3.5, 7.0
            ]
            """.trimIndent()
        )
}
