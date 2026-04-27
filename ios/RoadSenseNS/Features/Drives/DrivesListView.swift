import SwiftUI

struct DrivesListView: View {
    let readingStore: ReadingStore
    var mapboxAccessToken: String? = nil
    var onOpenOnMap: ((DriveBoundingBox) -> Void)?

    @Environment(\.dismiss) private var dismiss
    @State private var sections: [DriveListSection] = []
    @State private var loadError: String?
    @State private var deleteCandidate: DriveSummary?
    @State private var deleteError: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DesignTokens.Space.xl) {
                if let loadError {
                    Text(loadError)
                        .font(.system(size: 14))
                        .foregroundStyle(DesignTokens.Palette.danger)
                        .accessibilityIdentifier("drives.load-error")
                }

                if sections.isEmpty && loadError == nil {
                    emptyState
                } else {
                    ForEach(sections) { section in
                        sectionView(section)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, DesignTokens.Space.xl)
            .padding(.top, DesignTokens.Space.lg)
            .padding(.bottom, DesignTokens.Space.xxxl)
        }
        .background(backgroundGradient.ignoresSafeArea())
        .navigationTitle("Recent drives")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Done") { dismiss() }
                    .accessibilityIdentifier("drives.close")
            }
        }
        .task { reload() }
        .confirmationDialog(
            "Delete this drive?",
            isPresented: Binding(
                get: { deleteCandidate != nil },
                set: { if !$0 { deleteCandidate = nil } }
            ),
            titleVisibility: .visible,
            presenting: deleteCandidate
        ) { drive in
            Button("Delete drive", role: .destructive) {
                handleDelete(drive)
            }
            Button("Cancel", role: .cancel) {
                deleteCandidate = nil
            }
        } message: { _ in
            Text("Removes the drive from this device. Already uploaded data stays public — RoadSense doesn't track who sent it.")
        }
        .alert("Couldn't delete drive", isPresented: Binding(
            get: { deleteError != nil },
            set: { if !$0 { deleteError = nil } }
        )) {
            Button("OK", role: .cancel) { deleteError = nil }
        } message: {
            Text(deleteError ?? "")
        }
    }

    private var backgroundGradient: some View {
        LinearGradient(
            colors: [DesignTokens.Palette.canvas, DesignTokens.Palette.canvasSunken],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Space.sm) {
            Text("No drives yet.")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(DesignTokens.Palette.ink)
            Text("Once you start driving, completed trips will show up here. Each one lists how much was kept on-device, how much was filtered by your privacy zones, and how much made it to the public map.")
                .font(.system(size: 14))
                .foregroundStyle(DesignTokens.Palette.inkMuted)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(DesignTokens.Space.lg)
        .background(DesignTokens.Palette.surface, in: RoundedRectangle(cornerRadius: DesignTokens.Radius.md, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: DesignTokens.Radius.md, style: .continuous)
                .strokeBorder(DesignTokens.Palette.border, lineWidth: 1)
        )
    }

    private func sectionView(_ section: DriveListSection) -> some View {
        VStack(alignment: .leading, spacing: DesignTokens.Space.sm) {
            Text(section.bucket.displayName)
                .font(.system(size: 13, weight: .bold))
                .tracking(1.2)
                .textCase(.uppercase)
                .foregroundStyle(DesignTokens.Palette.inkMuted)

            VStack(spacing: DesignTokens.Space.sm) {
                ForEach(section.drives) { drive in
                    driveRow(drive)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func driveRow(_ drive: DriveSummary) -> some View {
        VStack(alignment: .leading, spacing: DesignTokens.Space.sm) {
            if let bbox = drive.bbox, let url = staticMapURL(for: bbox) {
                miniMapPreview(url: url)
            }

            HStack(alignment: .firstTextBaseline) {
                Text(timeRangeLabel(drive))
                    .font(.system(size: 17, weight: .semibold, design: .rounded))
                    .foregroundStyle(DesignTokens.Palette.ink)
                    .accessibilityIdentifier("drives.row.time")
                Spacer()
                Text(distanceLabel(drive))
                    .font(.system(size: 15, weight: .semibold).monospacedDigit())
                    .foregroundStyle(DesignTokens.Palette.ink)
                    .accessibilityIdentifier("drives.row.distance")
            }

            if drive.hasOnlyPrivacyFilteredData {
                Text("Inside a privacy zone — nothing left this device.")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(DesignTokens.Palette.smooth)
                    .accessibilityIdentifier("drives.row.privacy-zone")
            } else {
                HStack(spacing: DesignTokens.Space.lg) {
                    statChip(label: "Road data", value: "\(drive.acceptedReadingCount)")
                    if drive.privacyFilteredReadingCount > 0 {
                        statChip(
                            label: "Privacy-filtered",
                            value: "\(drive.privacyFilteredReadingCount)",
                            tint: DesignTokens.Palette.smooth
                        )
                    }
                    if drive.potholeCount > 0 {
                        statChip(
                            label: drive.potholeCount == 1 ? "Pothole" : "Potholes",
                            value: "\(drive.potholeCount)",
                            tint: DesignTokens.Palette.warning
                        )
                    }
                }
            }

            HStack {
                if let onOpenOnMap, let bbox = drive.bbox {
                    Button {
                        dismiss()
                        onOpenOnMap(bbox)
                    } label: {
                        Label("Open on map", systemImage: "map")
                            .font(.system(size: 13, weight: .semibold))
                            .labelStyle(.titleAndIcon)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .tint(DesignTokens.Palette.deep)
                    .accessibilityIdentifier("drives.row.open-on-map")
                }

                Spacer()

                Button(role: .destructive) {
                    deleteCandidate = drive
                } label: {
                    Text("Delete drive")
                        .font(.system(size: 13, weight: .semibold))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .tint(DesignTokens.Palette.danger)
                .accessibilityIdentifier("drives.row.delete")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(DesignTokens.Space.md)
        .background(DesignTokens.Palette.surface, in: RoundedRectangle(cornerRadius: DesignTokens.Radius.md, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: DesignTokens.Radius.md, style: .continuous)
                .strokeBorder(DesignTokens.Palette.border, lineWidth: 1)
        )
    }

    private func statChip(
        label: String,
        value: String,
        tint: Color = DesignTokens.Palette.deep
    ) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label.uppercased())
                .font(.system(size: 10, weight: .bold))
                .tracking(1.0)
                .foregroundStyle(DesignTokens.Palette.inkMuted)
            Text(value)
                .font(.system(size: 15, weight: .semibold, design: .rounded).monospacedDigit())
                .foregroundStyle(tint)
        }
    }

    private func timeRangeLabel(_ drive: DriveSummary) -> String {
        let start = drive.startedAt.formatted(date: .omitted, time: .shortened)
        if let endedAt = drive.endedAt {
            let end = endedAt.formatted(date: .omitted, time: .shortened)
            return "\(start) – \(end)"
        }
        return start
    }

    private func distanceLabel(_ drive: DriveSummary) -> String {
        if drive.distanceKm <= 0 {
            return "—"
        }
        if drive.distanceKm < 1 {
            return "\(Int(drive.distanceKm * 1_000)) m"
        }
        return "\(drive.distanceKm.formatted(.number.precision(.fractionLength(1)))) km"
    }

    private func reload() {
        do {
            let summaries = try readingStore.recentDriveSummaries()
            sections = DriveListGrouper.group(summaries, now: Date())
            loadError = nil
        } catch {
            loadError = error.localizedDescription
            sections = []
        }
    }

    private func handleDelete(_ drive: DriveSummary) {
        do {
            try readingStore.deleteDriveSession(id: drive.id)
            deleteCandidate = nil
            reload()
        } catch {
            deleteError = error.localizedDescription
            deleteCandidate = nil
        }
    }

    private func miniMapPreview(url: URL) -> some View {
        AsyncImage(url: url) { phase in
            switch phase {
            case .empty:
                RoundedRectangle(cornerRadius: DesignTokens.Radius.sm, style: .continuous)
                    .fill(DesignTokens.Palette.canvasSunken)
                    .overlay(ProgressView().tint(DesignTokens.Palette.inkMuted))
            case let .success(image):
                image
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            case .failure:
                RoundedRectangle(cornerRadius: DesignTokens.Radius.sm, style: .continuous)
                    .fill(DesignTokens.Palette.canvasSunken)
                    .overlay(
                        Image(systemName: "map")
                            .foregroundStyle(DesignTokens.Palette.inkMuted)
                    )
            @unknown default:
                EmptyView()
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: 100)
        .clipShape(RoundedRectangle(cornerRadius: DesignTokens.Radius.sm, style: .continuous))
        .accessibilityIdentifier("drives.row.mini-map")
    }

    func staticMapURL(for bbox: DriveBoundingBox) -> URL? {
        guard let token = mapboxAccessToken, !token.isEmpty else { return nil }
        return DrivesListView.staticMapURL(
            for: bbox,
            token: token,
            widthPoints: 320,
            heightPoints: 100
        )
    }

    static func staticMapURL(
        for bbox: DriveBoundingBox,
        token: String,
        widthPoints: Int,
        heightPoints: Int
    ) -> URL? {
        guard !token.isEmpty else { return nil }

        // Mapbox Static Images caps width and height at 1280; 2x devices already
        // get sharp rendering via the @2x flag.
        let width = max(60, min(widthPoints, 1280))
        let height = max(60, min(heightPoints, 1280))

        let center = (
            lat: (bbox.minLatitude + bbox.maxLatitude) / 2,
            lng: (bbox.minLongitude + bbox.maxLongitude) / 2
        )
        let zoom = staticMapZoom(for: bbox)

        // 5 decimal places ≈ 1 m precision; keeps URLs short and AsyncImage's
        // URL-based cache more effective.
        func fmt(_ value: Double) -> String {
            String(format: "%.5f", value)
        }

        let style = "mapbox/light-v11"
        let lon = fmt(center.lng)
        let lat = fmt(center.lat)
        let zoomString = String(format: "%.1f", zoom)
        let path = "/styles/v1/\(style)/static/\(lon),\(lat),\(zoomString),0,0/\(width)x\(height)@2x"

        var components = URLComponents()
        components.scheme = "https"
        components.host = "api.mapbox.com"
        components.path = path
        components.queryItems = [
            URLQueryItem(name: "access_token", value: token),
            URLQueryItem(name: "logo", value: "false"),
            URLQueryItem(name: "attribution", value: "false")
        ]
        return components.url
    }

    private static func staticMapZoom(for bbox: DriveBoundingBox) -> Double {
        let latSpan = max(bbox.maxLatitude - bbox.minLatitude, 0.0005)
        let lngSpan = max(bbox.maxLongitude - bbox.minLongitude, 0.0005)
        let span = max(latSpan, lngSpan)
        switch span {
        case ..<0.005: return 14
        case ..<0.02:  return 13
        case ..<0.05:  return 12
        case ..<0.15:  return 11
        case ..<0.4:   return 10
        case ..<1.0:   return 9
        default:       return 8
        }
    }
}
