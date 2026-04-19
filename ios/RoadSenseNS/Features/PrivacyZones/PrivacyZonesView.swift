import CoreLocation
import MapboxMaps
import SwiftUI

struct PrivacyZonesView: View {
    let store: PrivacyZoneStoring
    let onChange: () -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var zones: [PrivacyZoneRecord] = []
    @State private var draftLabel = "Home"
    @State private var draftRadiusM = 300.0
    @State private var draftCenter = CLLocationCoordinate2D(latitude: 44.6488, longitude: -63.5752)
    @State private var viewport: Viewport = .camera(
        center: CLLocationCoordinate2D(latitude: 44.6488, longitude: -63.5752),
        zoom: 13.6
    )
    @State private var errorMessage: String?
    @State private var hasAppliedInitialViewport = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                editorMap
                draftPanel
            }
            .background(Color(uiColor: .systemGroupedBackground))
            .navigationTitle("Privacy Zones")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
            .task {
                loadZones()
            }
        }
    }

    private var editorMap: some View {
        ZStack(alignment: .top) {
            Map(viewport: $viewport) {
                Puck2D()
                PrivacyZoneMapContent(
                    zones: zones,
                    draftCenter: draftCenter,
                    draftRadiusM: draftRadiusM
                )
            }
            .mapStyle(.standard(theme: .default))
            .gestureOptions(GestureOptions(pinchEnabled: true, rotateEnabled: false))
            .ornamentOptions(
                OrnamentOptions(
                    scaleBar: .init(visibility: .hidden),
                    compass: .init(visibility: .hidden)
                )
            )
            .onCameraChanged { event in
                updateDraftCenter(event.cameraState.center)
            }
            .onMapLoadingError { event in
                errorMessage = event.message
            }
            .frame(height: 380)
            .overlay(alignment: .center) {
                DraftReticle()
                    .allowsHitTesting(false)
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("Pan the map to position the center")
                    .font(.subheadline.weight(.semibold))
                Text("RoadSense filters readings inside this radius before upload. Keep it large enough to cover driveways, side streets, and common arrival paths.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(14)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .padding(.top, 14)
            .padding(.horizontal, 14)
        }
    }

    private var draftPanel: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 14) {
                    Text("Draft zone")
                        .font(.headline)

                    TextField("Label", text: $draftLabel)
                        .textInputAutocapitalization(.words)
                        .autocorrectionDisabled()
                        .textFieldStyle(.roundedBorder)

                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("Radius")
                            Spacer()
                            Text("\(Int(draftRadiusM)) m")
                                .foregroundStyle(.secondary)
                        }
                        Slider(value: $draftRadiusM, in: 250...600, step: 25)
                            .tint(Color(roadsenseHex: 0x187E74))
                    }

                    HStack(spacing: 12) {
                        coordinateChip(
                            title: "Latitude",
                            value: draftCenter.latitude.formatted(.number.precision(.fractionLength(4)))
                        )
                        coordinateChip(
                            title: "Longitude",
                            value: draftCenter.longitude.formatted(.number.precision(.fractionLength(4)))
                        )
                    }

                    Button("Save privacy zone") {
                        saveZone()
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(Color(roadsenseHex: 0x187E74))
                    .disabled(draftLabel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                .padding(18)
                .background(.background, in: RoundedRectangle(cornerRadius: 22, style: .continuous))

                VStack(alignment: .leading, spacing: 12) {
                    Text("Saved zones")
                        .font(.headline)

                    if zones.isEmpty {
                        Text("No privacy zones yet. Add at least one before passive collection starts.")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(zones, id: \.id) { zone in
                            savedZoneRow(zone)
                        }
                    }
                }
                .padding(18)
                .background(.background, in: RoundedRectangle(cornerRadius: 22, style: .continuous))

                if let errorMessage {
                    Text(errorMessage)
                        .font(.footnote)
                        .foregroundStyle(.red)
                }
            }
            .padding(16)
        }
    }

    private func coordinateChip(title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.subheadline.monospacedDigit())
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private func savedZoneRow(_ zone: PrivacyZoneRecord) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(zone.label)
                        .font(.subheadline.weight(.semibold))
                    Text("\(zone.latitude.formatted(.number.precision(.fractionLength(4)))), \(zone.longitude.formatted(.number.precision(.fractionLength(4))))")
                        .font(.footnote.monospacedDigit())
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 12)

                Text("\(Int(zone.radiusM)) m")
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(Color(roadsenseHex: 0x187E74))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(Color(roadsenseHex: 0x187E74).opacity(0.12), in: Capsule())
            }

            HStack(spacing: 10) {
                Button("Focus on map") {
                    focus(on: zone)
                }
                .buttonStyle(.bordered)

                Button("Delete", role: .destructive) {
                    deleteZone(zone)
                }
                .buttonStyle(.bordered)
            }
        }
        .padding(.bottom, 4)
    }

    private func loadZones() {
        do {
            zones = try store.fetchAll()
            errorMessage = nil

            guard !hasAppliedInitialViewport else { return }
            if let firstZone = zones.first {
                let center = CLLocationCoordinate2D(latitude: firstZone.latitude, longitude: firstZone.longitude)
                draftCenter = center
                draftLabel = firstZone.label
                draftRadiusM = firstZone.radiusM
                viewport = .camera(center: center, zoom: 14.2)
            }
            hasAppliedInitialViewport = true
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func saveZone() {
        do {
            try store.save(
                label: draftLabel.trimmingCharacters(in: .whitespacesAndNewlines),
                latitude: draftCenter.latitude,
                longitude: draftCenter.longitude,
                radiusM: draftRadiusM
            )
            errorMessage = nil
            draftLabel = nextSuggestedLabel()
            loadZones()
            onChange()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func deleteZone(_ zone: PrivacyZoneRecord) {
        do {
            try store.delete(id: zone.id)
            errorMessage = nil
            loadZones()
            onChange()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func focus(on zone: PrivacyZoneRecord) {
        let center = CLLocationCoordinate2D(latitude: zone.latitude, longitude: zone.longitude)
        draftCenter = center
        draftRadiusM = zone.radiusM
        draftLabel = zone.label
        viewport = .camera(center: center, zoom: zoomLevel(for: zone.radiusM))
    }

    private func updateDraftCenter(_ center: CLLocationCoordinate2D) {
        let distance = PrivacyZoneFactory.distanceMeters(
            fromLatitude: draftCenter.latitude,
            fromLongitude: draftCenter.longitude,
            toLatitude: center.latitude,
            toLongitude: center.longitude
        )

        guard distance > 4 else { return }
        draftCenter = center
    }

    private func nextSuggestedLabel() -> String {
        let existingLabels = Set(zones.map { $0.label.lowercased() })
        let suggestions = ["Work", "Partner", "Family", "School"]

        if let suggestion = suggestions.first(where: { !existingLabels.contains($0.lowercased()) }) {
            return suggestion
        }

        return "Privacy zone \(zones.count + 1)"
    }

    private func zoomLevel(for radiusM: Double) -> Double {
        switch radiusM {
        case ..<275:
            return 15.2
        case ..<400:
            return 14.6
        case ..<525:
            return 14.1
        default:
            return 13.7
        }
    }
}

private struct DraftReticle: View {
    var body: some View {
        ZStack {
            Circle()
                .fill(.white)
                .frame(width: 14, height: 14)
                .overlay(
                    Circle()
                        .stroke(Color(roadsenseHex: 0x187E74), lineWidth: 3)
                )

            Rectangle()
                .fill(.white.opacity(0.86))
                .frame(width: 2, height: 26)

            Rectangle()
                .fill(.white.opacity(0.86))
                .frame(width: 26, height: 2)
        }
        .shadow(color: .black.opacity(0.18), radius: 10, y: 4)
    }
}

private struct PrivacyZoneMapContent: MapContent {
    let zones: [PrivacyZoneRecord]
    let draftCenter: CLLocationCoordinate2D
    let draftRadiusM: Double

    var body: some MapContent {
        PolygonAnnotation(polygon: draftPolygon)
            .fillColor(UIColor(Color(roadsenseHex: 0x187E74).opacity(0.18)))
            .fillOutlineColor(UIColor(Color(roadsenseHex: 0x187E74)))

        CircleAnnotation(centerCoordinate: draftCenter)
            .circleColor(UIColor(Color(roadsenseHex: 0x187E74)))
            .circleStrokeColor(.white)
            .circleStrokeWidth(2)
            .circleRadius(6)

        PolygonAnnotationGroup(zones) { zone in
            PolygonAnnotation(polygon: polygon(for: zone))
                .fillColor(UIColor(Color(roadsenseHex: 0x2C6E91).opacity(0.12)))
                .fillOutlineColor(UIColor(Color(roadsenseHex: 0x2C6E91)))
        }

        CircleAnnotationGroup(zones) { zone in
            CircleAnnotation(centerCoordinate: CLLocationCoordinate2D(latitude: zone.latitude, longitude: zone.longitude))
                .circleColor(UIColor(Color(roadsenseHex: 0x2C6E91)))
                .circleStrokeColor(.white)
                .circleStrokeWidth(2)
                .circleRadius(5)
        }
    }

    private var draftPolygon: Polygon {
        polygon(
            latitude: draftCenter.latitude,
            longitude: draftCenter.longitude,
            radiusM: draftRadiusM
        )
    }

    private func polygon(for zone: PrivacyZoneRecord) -> Polygon {
        polygon(
            latitude: zone.latitude,
            longitude: zone.longitude,
            radiusM: zone.radiusM
        )
    }

    private func polygon(latitude: Double, longitude: Double, radiusM: Double) -> Polygon {
        let coordinates = PrivacyZoneFactory.boundaryCoordinates(
            centerLatitude: latitude,
            centerLongitude: longitude,
            radiusMeters: radiusM,
            vertices: 40
        )
        .map { CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude) }

        return Polygon([coordinates])
    }
}
