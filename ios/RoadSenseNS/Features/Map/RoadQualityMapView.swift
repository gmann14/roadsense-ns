import CoreLocation
import MapboxMaps
import SwiftUI

struct RoadQualityMapView: View {
    let config: AppConfig
    let localDriveOverlayPoints: [LocalDriveOverlayPoint]
    let pendingPotholeCoordinates: [CLLocationCoordinate2D]
    @Binding var pendingMapTarget: DriveBoundingBox?
    let onMapLoaded: () -> Void
    let onMapLoadingError: (String) -> Void
    let onSelectSegment: (UUID) -> Void
    let onClearSelection: () -> Void

    @State private var viewport: Viewport = .followPuck(zoom: 13.8, bearing: .constant(0))

    var body: some View {
        Group {
            if AppBootstrap.isRunningTests {
                TestingRoadQualityMapView(
                    localDriveOverlayPoints: localDriveOverlayPoints,
                    pendingPotholeCoordinates: pendingPotholeCoordinates,
                    onMapLoaded: onMapLoaded
                )
            } else {
                liveMap
            }
        }
    }

    private var liveMap: some View {
        MapReader { proxy in
            Map(viewport: $viewport) {
                Puck2D(bearing: .heading)
                    .showsAccuracyRing(true)

                RoadQualityMapStyleContent(tileTemplateURL: Endpoints(config: config).tileTemplateURLString)
                LocalDriveOverlayStyleContent(points: localDriveOverlayPoints)
                PendingPotholeOverlayStyleContent(coordinates: pendingPotholeCoordinates)

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
            .onMapLoaded { _ in
                onMapLoaded()
            }
            .onMapLoadingError { event in
                onMapLoadingError(event.message)
            }
            .ignoresSafeArea()
            .onChange(of: pendingMapTarget) { _, newTarget in
                applyPendingTarget(newTarget)
            }
        }
    }

    private func applyPendingTarget(_ target: DriveBoundingBox?) {
        guard let target else { return }
        viewport = .camera(
            center: cameraCenter(of: target),
            zoom: cameraZoom(for: target),
            bearing: 0,
            pitch: 0
        )
        // Clear the request so the binding can fire again next time.
        pendingMapTarget = nil
    }

    private func cameraCenter(of bbox: DriveBoundingBox) -> CLLocationCoordinate2D {
        CLLocationCoordinate2D(
            latitude: (bbox.minLatitude + bbox.maxLatitude) / 2,
            longitude: (bbox.minLongitude + bbox.maxLongitude) / 2
        )
    }

    private func cameraZoom(for bbox: DriveBoundingBox) -> Double {
        // Pick a Mapbox zoom that comfortably fits the bbox. The bbox spans are
        // small (single-drive scale), so the heuristic doesn't have to be exact —
        // it just needs to land somewhere between street-level (16) and city-level
        // (10) so the whole drive is visible.
        let latSpan = max(bbox.maxLatitude - bbox.minLatitude, 0.0005)
        let lngSpan = max(bbox.maxLongitude - bbox.minLongitude, 0.0005)
        let span = max(latSpan, lngSpan)

        switch span {
        case ..<0.005: return 15
        case ..<0.02:  return 14
        case ..<0.05:  return 13
        case ..<0.15:  return 12
        case ..<0.4:   return 11
        case ..<1.0:   return 10
        default:       return 9
        }
    }
}

private struct TestingRoadQualityMapView: View {
    let localDriveOverlayPoints: [LocalDriveOverlayPoint]
    let pendingPotholeCoordinates: [CLLocationCoordinate2D]
    let onMapLoaded: () -> Void

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [
                    DesignTokens.Palette.deepInk,
                    DesignTokens.Palette.deep,
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )

            VStack(spacing: 14) {
                Image(systemName: "map.fill")
                    .font(.system(size: 42, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.92))

                Text("Testing map surface")
                    .font(.headline.weight(.semibold))
                    .foregroundStyle(.white)

                Text(
                    localDriveOverlayPoints.isEmpty && pendingPotholeCoordinates.isEmpty
                        ? "UI tests run against a deterministic non-Mapbox map shell."
                        : "Pending local drive or pothole overlay data is present in the test shell."
                )
                .font(.subheadline)
                .multilineTextAlignment(.center)
                .foregroundStyle(.white.opacity(0.82))
                .frame(maxWidth: 280)
            }
            .padding(24)
            .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        }
        .ignoresSafeArea()
        .accessibilityIdentifier("map.testing-surface")
        .task {
            onMapLoaded()
        }
    }
}

private struct LocalDriveOverlayStyleContent: MapStyleContent {
    let points: [LocalDriveOverlayPoint]

    var body: some MapStyleContent {
        LocalDriveCategoryOverlayStyleContent(
            category: "smooth",
            color: DesignTokens.Palette.smooth,
            segments: segments(for: "smooth")
        )
        LocalDriveCategoryOverlayStyleContent(
            category: "fair",
            color: DesignTokens.Palette.fair,
            segments: segments(for: "fair")
        )
        LocalDriveCategoryOverlayStyleContent(
            category: "rough",
            color: DesignTokens.Palette.rough,
            segments: segments(for: "rough")
        )
        LocalDriveCategoryOverlayStyleContent(
            category: "very_rough",
            color: DesignTokens.Palette.veryRough,
            segments: segments(for: "very_rough")
        )
    }

    private func segments(for category: String) -> [[CLLocationCoordinate2D]] {
        guard points.count >= 2 else { return [] }

        return zip(points, points.dropFirst()).compactMap { previous, current in
            guard current.roughnessCategory == category else { return nil }
            return [previous.coordinate, current.coordinate]
        }
    }
}

private struct LocalDriveCategoryOverlayStyleContent: MapStyleContent {
    let category: String
    let color: Color
    let segments: [[CLLocationCoordinate2D]]

    var body: some MapStyleContent {
        if !segments.isEmpty {
            GeoJSONSource(id: sourceID)
                .data(localDriveGeoJSON)

            LineLayer(id: layerID, source: sourceID)
                .lineCap(.round)
                .lineJoin(.round)
                .lineColor(StyleColor(color))
                .lineOpacity(0.95)
                .lineWidth(localDriveWidthExpression)
                .lineDashArray([2.0, 2.0])
        }
    }

    private var sourceID: String {
        "roadsense-local-drive-\(category)-source"
    }

    private var layerID: String {
        "roadsense-local-drive-\(category)-line"
    }

    private var localDriveGeoJSON: GeoJSONSourceData {
        let features = segments.map { coordinates in
            Feature(geometry: Geometry(LineString(coordinates)))
        }
        return .featureCollection(FeatureCollection(features: features))
    }

    private var localDriveWidthExpression: Exp {
        Exp(.interpolate) {
            Exp(.linear)
            Exp(.zoom)
            10
            2.0
            14
            3.5
            18
            6.5
        }
    }
}

private struct PendingPotholeOverlayStyleContent: MapStyleContent {
    static let sourceID = "roadsense-pending-pothole-source"
    static let layerID = "roadsense-pending-potholes"

    let coordinates: [CLLocationCoordinate2D]

    var body: some MapStyleContent {
        if !coordinates.isEmpty {
            GeoJSONSource(id: Self.sourceID)
                .data(pendingPotholeGeoJSON)

            CircleLayer(id: Self.layerID, source: Self.sourceID)
                .circleColor(StyleColor(DesignTokens.Palette.warning))
                .circleStrokeColor(StyleColor(.white))
                .circleStrokeWidth(2)
                .circleRadius(radiusExpression)
                .circleOpacity(0.88)
        }
    }

    private var pendingPotholeGeoJSON: GeoJSONSourceData {
        let features = coordinates.map { coordinate in
            Feature(geometry: Geometry(Point(coordinate)))
        }
        return .featureCollection(FeatureCollection(features: features))
    }

    private var radiusExpression: Exp {
        Exp(.interpolate) {
            Exp(.linear)
            Exp(.zoom)
            10
            4.0
            14
            6.0
            18
            8.5
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
        Exp(.match) {
            Exp(.get) { "category" }
            "smooth"
            UIColor(DesignTokens.Palette.smooth)
            "fair"
            UIColor(DesignTokens.Palette.fair)
            "rough"
            UIColor(DesignTokens.Palette.rough)
            "very_rough"
            UIColor(DesignTokens.Palette.veryRough)
            "unpaved"
            UIColor(DesignTokens.Palette.warning)
            UIColor(DesignTokens.Palette.inkMuted)
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
