import CoreLocation
import MapboxMaps
import SwiftUI

struct RoadQualityMapView: View {
    let config: AppConfig
    let onSelectSegment: (UUID) -> Void
    let onClearSelection: () -> Void

    @State private var viewport: Viewport = .camera(
        center: CLLocationCoordinate2D(latitude: 44.6488, longitude: -63.5752),
        zoom: 11.8
    )

    var body: some View {
        MapReader { proxy in
            Map(viewport: $viewport) {
                Puck2D()

                RoadQualityMapStyleContent(tileTemplateURL: Endpoints(config: config).tileTemplateURLString)

                TapInteraction(.layer(RoadQualityMapStyleContent.segmentLayerID)) { feature, _ in
                    guard let map = proxy.map,
                          let featureID = feature.id?.id,
                          let segmentID = UUID(uuidString: featureID) else {
                        return false
                    }

                    map.resetFeatureStates(
                        sourceId: RoadQualityMapStyleContent.sourceID,
                        sourceLayerId: RoadQualityMapStyleContent.segmentSourceLayer
                    ) { _ in }
                    map.setFeatureState(feature, state: ["selected": true]) { _ in }

                    onSelectSegment(segmentID)
                    return true
                }

                TapInteraction { _ in
                    proxy.map?.resetFeatureStates(
                        sourceId: RoadQualityMapStyleContent.sourceID,
                        sourceLayerId: RoadQualityMapStyleContent.segmentSourceLayer
                    ) { _ in }
                    onClearSelection()
                    return false
                }
            }
            .mapStyle(.standard(theme: .default))
            .ornamentOptions(
                OrnamentOptions(
                    scaleBar: .init(visibility: .hidden),
                    compass: .init(visibility: .hidden)
                )
            )
            .ignoresSafeArea()
        }
    }
}

private struct RoadQualityMapStyleContent: MapStyleContent {
    static let sourceID = "roadsense-quality-source"
    static let potholeSourceID = "roadsense-pothole-source"
    static let segmentSourceLayer = "segment_aggregates"
    static let potholeSourceLayer = "potholes"
    static let segmentLayerID = "roadsense-quality-line"
    static let segmentSelectionLayerID = "roadsense-quality-line-selected"
    static let potholeLayerID = "roadsense-potholes"

    let tileTemplateURL: String

    var body: some MapStyleContent {
        VectorSource(id: Self.sourceID)
            .tiles([tileTemplateURL])
            .minzoom(10)
            .maxzoom(16)

        LineLayer(id: Self.segmentLayerID, source: Self.sourceID)
            .sourceLayer(Self.segmentSourceLayer)
            .lineCap(.round)
            .lineJoin(.round)
            .lineColor(segmentColorExpression)
            .lineOpacity(segmentOpacityExpression)
            .lineWidth(segmentWidthExpression)

        LineLayer(id: Self.segmentSelectionLayerID, source: Self.sourceID)
            .sourceLayer(Self.segmentSourceLayer)
            .lineCap(.round)
            .lineJoin(.round)
            .lineColor(.white)
            .lineOpacity(selectedOpacityExpression)
            .lineWidth(selectedWidthExpression)

        VectorSource(id: Self.potholeSourceID)
            .tiles([tileTemplateURL])
            .minzoom(13)
            .maxzoom(16)

        CircleLayer(id: Self.potholeLayerID, source: Self.potholeSourceID)
            .sourceLayer(Self.potholeSourceLayer)
            .circleColor(StyleColor(.systemRed))
            .circleStrokeColor(StyleColor(.white))
            .circleStrokeWidth(1.5)
            .circleRadius(potholeRadiusExpression)
            .circleOpacity(0.9)
    }

    private var segmentColorExpression: Exp {
        Exp(.interpolate) {
            Exp(.linear)
            Exp(.get) { "roughness_score" }
            0.3
            UIColor(Color(roadsenseHex: 0x2CB67D))
            0.6
            UIColor(Color(roadsenseHex: 0xF4D35E))
            1.0
            UIColor(Color(roadsenseHex: 0xF28C28))
            1.5
            UIColor(Color(roadsenseHex: 0xD64550))
        }
    }

    private var segmentOpacityExpression: Exp {
        Exp(.switchCase) {
            Exp(.eq) {
                Exp(.get) { "confidence" }
                "low"
            }
            0.4
            Exp(.eq) {
                Exp(.get) { "confidence" }
                "medium"
            }
            0.72
            0.96
        }
    }

    private var segmentWidthExpression: Exp {
        Exp(.interpolate) {
            Exp(.linear)
            Exp(.zoom)
            10
            1.5
            14
            3.0
            18
            6.0
        }
    }

    private var selectedOpacityExpression: Exp {
        Exp(.switchCase) {
            Exp(.boolean) {
                Exp(.featureState) { "selected" }
                false
            }
            0.98
            0.0
        }
    }

    private var selectedWidthExpression: Exp {
        Exp(.switchCase) {
            Exp(.boolean) {
                Exp(.featureState) { "selected" }
                false
            }
            Exp(.interpolate) {
                Exp(.linear)
                Exp(.zoom)
                10
                3.0
                14
                5.0
                18
                8.0
            }
            0.0
        }
    }

    private var potholeRadiusExpression: Exp {
        Exp(.interpolate) {
            Exp(.linear)
            Exp(.coalesce) {
                Exp(.get) { "magnitude" }
                1.0
            }
            1.0
            3.0
            3.5
            7.0
        }
    }
}
