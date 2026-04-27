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
    @State private var zoneToDelete: PrivacyZoneRecord?

    var body: some View {
        NavigationStack {
            ZStack(alignment: .top) {
                backgroundGradient.ignoresSafeArea()
                ScrollView {
                    VStack(spacing: DesignTokens.Space.lg) {
                        editorMap
                        draftCard
                        savedZonesCard

                        if let errorMessage {
                            Text(errorMessage)
                                .font(.system(size: 14))
                                .foregroundStyle(DesignTokens.Palette.danger)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    .padding(.horizontal, DesignTokens.Space.xl)
                    .padding(.top, DesignTokens.Space.md)
                    .padding(.bottom, DesignTokens.Space.xxxl)
                }
            }
            .navigationTitle("Privacy Zones")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                        .accessibilityIdentifier("privacy-zones.close")
                }
            }
            .task { loadZones() }
            .confirmationDialog(
                "Remove this privacy zone?",
                isPresented: Binding(
                    get: { zoneToDelete != nil },
                    set: { if !$0 { zoneToDelete = nil } }
                ),
                titleVisibility: .visible,
                presenting: zoneToDelete
            ) { zone in
                Button("Delete \(zone.label)", role: .destructive) { deleteZone(zone) }
                Button("Cancel", role: .cancel) { zoneToDelete = nil }
            } message: { zone in
                Text("Drive samples inside \(zone.label) will again be uploaded after deletion.")
            }
        }
    }

    private var backgroundGradient: some View {
        LinearGradient(
            colors: [DesignTokens.Palette.canvas, DesignTokens.Palette.canvasSunken],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    // MARK: - Map + hint

    private var editorMap: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Space.md) {
            Text("DRAFT ZONE")
                .font(.system(size: 11, weight: .bold))
                .tracking(1.3)
                .foregroundStyle(DesignTokens.Palette.inkMuted)

            Text("Pan the map to position the center")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(DesignTokens.Palette.ink)

            Text("RoadSense filters drive samples inside this radius before upload. Keep it large enough to cover driveways, side streets, and common arrival paths.")
                .font(.system(size: 13))
                .foregroundStyle(DesignTokens.Palette.inkMuted)
                .fixedSize(horizontal: false, vertical: true)

            ZStack {
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
                    errorMessage = AppBootstrap.formatMapLoadError(event.message)
                }
                .frame(height: 320)
                .clipShape(RoundedRectangle(cornerRadius: DesignTokens.Radius.md, style: .continuous))
                .overlay(alignment: .center) {
                    DraftReticle()
                        .allowsHitTesting(false)
                }
                .overlay(
                    RoundedRectangle(cornerRadius: DesignTokens.Radius.md, style: .continuous)
                        .strokeBorder(DesignTokens.Palette.border, lineWidth: 1)
                )
            }
            .accessibilityIdentifier("privacy-zones.map")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(DesignTokens.Space.lg)
        .background(
            RoundedRectangle(cornerRadius: DesignTokens.Radius.md, style: .continuous)
                .fill(DesignTokens.Palette.surface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: DesignTokens.Radius.md, style: .continuous)
                .strokeBorder(DesignTokens.Palette.border, lineWidth: 1)
        )
    }

    // MARK: - Draft panel

    private var draftCard: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Space.md) {
            HStack(spacing: DesignTokens.Space.sm) {
                ZStack {
                    Circle()
                        .fill(DesignTokens.Palette.deep.opacity(0.14))
                        .frame(width: 36, height: 36)
                    Image(systemName: "mappin.and.ellipse")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(DesignTokens.Palette.deep)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text("Zone details")
                        .font(.system(size: 18, weight: .semibold, design: .rounded))
                        .foregroundStyle(DesignTokens.Palette.ink)
                    Text("Label the location and pick a radius that fully covers the area.")
                        .font(.system(size: 13))
                        .foregroundStyle(DesignTokens.Palette.inkMuted)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            VStack(alignment: .leading, spacing: DesignTokens.Space.xs) {
                Text("Label")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(DesignTokens.Palette.inkMuted)
                TextField("Label", text: $draftLabel)
                    .textInputAutocapitalization(.words)
                    .autocorrectionDisabled()
                    .font(.system(size: 16))
                    .padding(.horizontal, DesignTokens.Space.sm)
                    .padding(.vertical, DesignTokens.Space.sm)
                    .background(
                        RoundedRectangle(cornerRadius: DesignTokens.Radius.sm, style: .continuous)
                            .fill(DesignTokens.Palette.canvasSunken)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: DesignTokens.Radius.sm, style: .continuous)
                            .strokeBorder(DesignTokens.Palette.border, lineWidth: 1)
                    )
            }

            VStack(alignment: .leading, spacing: DesignTokens.Space.xs) {
                HStack {
                    Text("Radius")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(DesignTokens.Palette.inkMuted)
                    Spacer()
                    Text("\(Int(draftRadiusM)) m")
                        .font(.system(size: 13, weight: .semibold, design: .rounded).monospacedDigit())
                        .foregroundStyle(DesignTokens.Palette.ink)
                }
                Slider(value: $draftRadiusM, in: 250...600, step: 25)
                    .tint(DesignTokens.Palette.deep)
            }

            HStack(spacing: DesignTokens.Space.sm) {
                coordinateChip(
                    title: "Latitude",
                    value: draftCenter.latitude.formatted(.number.precision(.fractionLength(4)))
                )
                coordinateChip(
                    title: "Longitude",
                    value: draftCenter.longitude.formatted(.number.precision(.fractionLength(4)))
                )
            }

            Button {
                saveZone()
            } label: {
                Text("Save privacy zone")
                    .font(.system(size: 16, weight: .semibold))
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(DesignTokens.Palette.deep)
            .controlSize(.large)
            .disabled(draftLabel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            .accessibilityIdentifier("privacy-zones.save")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(DesignTokens.Space.lg)
        .background(
            RoundedRectangle(cornerRadius: DesignTokens.Radius.md, style: .continuous)
                .fill(DesignTokens.Palette.surface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: DesignTokens.Radius.md, style: .continuous)
                .strokeBorder(DesignTokens.Palette.border, lineWidth: 1)
        )
    }

    // MARK: - Saved zones

    private var savedZonesCard: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Space.md) {
            HStack(spacing: DesignTokens.Space.sm) {
                ZStack {
                    Circle()
                        .fill(DesignTokens.Palette.smooth.opacity(0.14))
                        .frame(width: 36, height: 36)
                    Image(systemName: "lock.shield")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(DesignTokens.Palette.smooth)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text("Saved zones")
                        .font(.system(size: 18, weight: .semibold, design: .rounded))
                        .foregroundStyle(DesignTokens.Palette.ink)
                    Text(zones.isEmpty
                         ? "Add at least one before passive collection starts."
                         : "Tap a zone to focus or delete it.")
                        .font(.system(size: 13))
                        .foregroundStyle(DesignTokens.Palette.inkMuted)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            if zones.isEmpty {
                VStack(alignment: .leading, spacing: DesignTokens.Space.xs) {
                    Text("No privacy zones yet")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(DesignTokens.Palette.ink)
                    Text("No privacy zones yet. Add at least one before passive collection starts.")
                        .font(.system(size: 13))
                        .foregroundStyle(DesignTokens.Palette.inkMuted)
                        .accessibilityIdentifier("privacy-zones.empty")
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(DesignTokens.Space.md)
                .background(
                    RoundedRectangle(cornerRadius: DesignTokens.Radius.sm, style: .continuous)
                        .fill(DesignTokens.Palette.canvasSunken)
                )
            } else {
                VStack(spacing: DesignTokens.Space.sm) {
                    ForEach(zones, id: \.id) { zone in
                        savedZoneRow(zone)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(DesignTokens.Space.lg)
        .background(
            RoundedRectangle(cornerRadius: DesignTokens.Radius.md, style: .continuous)
                .fill(DesignTokens.Palette.surface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: DesignTokens.Radius.md, style: .continuous)
                .strokeBorder(DesignTokens.Palette.border, lineWidth: 1)
        )
    }

    private func coordinateChip(title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title.uppercased())
                .font(.system(size: 10, weight: .bold))
                .tracking(1.2)
                .foregroundStyle(DesignTokens.Palette.inkMuted)
            Text(value)
                .font(.system(size: 15, weight: .semibold, design: .rounded).monospacedDigit())
                .foregroundStyle(DesignTokens.Palette.ink)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, DesignTokens.Space.sm)
        .padding(.vertical, DesignTokens.Space.sm)
        .background(
            RoundedRectangle(cornerRadius: DesignTokens.Radius.sm, style: .continuous)
                .fill(DesignTokens.Palette.canvasSunken)
        )
        .overlay(
            RoundedRectangle(cornerRadius: DesignTokens.Radius.sm, style: .continuous)
                .strokeBorder(DesignTokens.Palette.border, lineWidth: 1)
        )
    }

    private func savedZoneRow(_ zone: PrivacyZoneRecord) -> some View {
        VStack(alignment: .leading, spacing: DesignTokens.Space.sm) {
            HStack(alignment: .top, spacing: DesignTokens.Space.sm) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(zone.label)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(DesignTokens.Palette.ink)
                        .accessibilityIdentifier("privacy-zone.\(zone.label)")
                    Text("\(zone.latitude.formatted(.number.precision(.fractionLength(4)))), \(zone.longitude.formatted(.number.precision(.fractionLength(4))))")
                        .font(.system(size: 12, design: .rounded).monospacedDigit())
                        .foregroundStyle(DesignTokens.Palette.inkMuted)
                }

                Spacer(minLength: DesignTokens.Space.sm)

                Text("\(Int(zone.radiusM)) m")
                    .font(.system(size: 12, weight: .semibold, design: .rounded).monospacedDigit())
                    .foregroundStyle(DesignTokens.Palette.deep)
                    .padding(.horizontal, DesignTokens.Space.sm)
                    .padding(.vertical, 6)
                    .background(DesignTokens.Palette.deep.opacity(0.12), in: Capsule())
            }

            HStack(spacing: DesignTokens.Space.sm) {
                Button {
                    focus(on: zone)
                } label: {
                    Label("Focus on map", systemImage: "scope")
                        .font(.system(size: 13, weight: .semibold))
                }
                .buttonStyle(.bordered)
                .tint(DesignTokens.Palette.deep)
                .controlSize(.small)

                Button(role: .destructive) {
                    zoneToDelete = zone
                } label: {
                    Label("Delete", systemImage: "trash")
                        .font(.system(size: 13, weight: .semibold))
                }
                .buttonStyle(.bordered)
                .tint(DesignTokens.Palette.danger)
                .controlSize(.small)
            }
        }
        .padding(DesignTokens.Space.md)
        .background(
            RoundedRectangle(cornerRadius: DesignTokens.Radius.sm, style: .continuous)
                .fill(DesignTokens.Palette.canvasSunken)
        )
        .overlay(
            RoundedRectangle(cornerRadius: DesignTokens.Radius.sm, style: .continuous)
                .strokeBorder(DesignTokens.Palette.border, lineWidth: 1)
        )
    }

    // MARK: - State helpers

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
            zoneToDelete = nil
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
                        .stroke(DesignTokens.Palette.deep, lineWidth: 3)
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
            .fillColor(UIColor(DesignTokens.Palette.deep.opacity(0.18)))
            .fillOutlineColor(UIColor(DesignTokens.Palette.deep))

        CircleAnnotation(centerCoordinate: draftCenter)
            .circleColor(UIColor(DesignTokens.Palette.deep))
            .circleStrokeColor(.white)
            .circleStrokeWidth(2)
            .circleRadius(6)

        PolygonAnnotationGroup(zones) { zone in
            PolygonAnnotation(polygon: polygon(for: zone))
                .fillColor(UIColor(DesignTokens.Palette.inkMuted.opacity(0.12)))
                .fillOutlineColor(UIColor(DesignTokens.Palette.inkMuted))
        }

        CircleAnnotationGroup(zones) { zone in
            CircleAnnotation(centerCoordinate: CLLocationCoordinate2D(latitude: zone.latitude, longitude: zone.longitude))
                .circleColor(UIColor(DesignTokens.Palette.inkMuted))
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
