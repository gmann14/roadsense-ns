import SwiftUI

struct PrivacyZonesView: View {
    let store: PrivacyZoneStoring
    let onChange: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var zones: [PrivacyZoneRecord] = []
    @State private var label = ""
    @State private var latitude = ""
    @State private var longitude = ""
    @State private var radiusM = "250"
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Form {
                Section("Current zones") {
                    if zones.isEmpty {
                        Text("No privacy zones yet. Add at least one before passive collection starts.")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(zones, id: \.id) { zone in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(zone.label).font(.headline)
                                Text("\(zone.latitude, format: .number.precision(.fractionLength(4))), \(zone.longitude, format: .number.precision(.fractionLength(4)))")
                                Text("Radius \(Int(zone.radiusM)) m")
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .onDelete(perform: deleteZones)
                    }
                }

                Section("Add zone") {
                    TextField("Label", text: $label)
                    TextField("Latitude", text: $latitude)
                        .keyboardType(.numbersAndPunctuation)
                    TextField("Longitude", text: $longitude)
                        .keyboardType(.numbersAndPunctuation)
                    TextField("Radius (m)", text: $radiusM)
                        .keyboardType(.numberPad)

                    Button("Save privacy zone") {
                        saveZone()
                    }
                    .disabled(label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }

                if let errorMessage {
                    Section {
                        Text(errorMessage)
                            .foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle("Privacy Zones")
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

    private func loadZones() {
        do {
            zones = try store.fetchAll()
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func saveZone() {
        guard let latitudeValue = Double(latitude),
              let longitudeValue = Double(longitude),
              let radiusValue = Double(radiusM) else {
            errorMessage = "Enter numeric latitude, longitude, and radius values."
            return
        }

        do {
            try store.save(
                label: label.trimmingCharacters(in: .whitespacesAndNewlines),
                latitude: latitudeValue,
                longitude: longitudeValue,
                radiusM: radiusValue
            )
            label = ""
            latitude = ""
            longitude = ""
            radiusM = "250"
            loadZones()
            onChange()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func deleteZones(at offsets: IndexSet) {
        do {
            for index in offsets {
                try store.delete(id: zones[index].id)
            }
            loadZones()
            onChange()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
