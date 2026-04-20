import Foundation

struct HarnessFixtureDefinition: Identifiable, Hashable {
    let id: String
    let title: String
    let summary: String
}

struct LoadedHarnessFixture {
    let definition: HarnessFixtureDefinition
    let fixture: SensorFixture
    let expected: SensorFixtureExpected
}

enum HarnessFixtureCatalog {
    static let fixtures: [HarnessFixtureDefinition] = [
        HarnessFixtureDefinition(
            id: "pothole-hit",
            title: "Pothole Hit",
            summary: "Single driving window with one pothole spike and one accepted reading."
        ),
        HarnessFixtureDefinition(
            id: "privacy-zone-recovery",
            title: "Privacy Zone Recovery",
            summary: "Starts inside a filtered zone, then recovers into one accepted window outside the zone."
        ),
        HarnessFixtureDefinition(
            id: "thermal-reject",
            title: "Thermal Reject",
            summary: "Produces a valid driving window that is rejected because the device enters a serious thermal state."
        ),
        HarnessFixtureDefinition(
            id: "smooth-cruise",
            title: "Smooth Cruise",
            summary: "Single accepted window with low roughness and no pothole spike."
        ),
    ]

    static func load(_ definition: HarnessFixtureDefinition) throws -> LoadedHarnessFixture {
        let bundle = Bundle.main
        guard let csvURL = bundle.url(forResource: definition.id, withExtension: "csv") else {
            throw CocoaError(.fileNoSuchFile)
        }

        guard let expectedURL = bundle.url(forResource: "\(definition.id).expected", withExtension: "json") else {
            throw CocoaError(.fileNoSuchFile)
        }

        let csv = try String(contentsOf: csvURL, encoding: .utf8)
        let expectedData = try Data(contentsOf: expectedURL)
        let expected = try JSONDecoder().decode(SensorFixtureExpected.self, from: expectedData)
        let fixture = try SensorFixtureParser.parse(csv: csv)

        return LoadedHarnessFixture(
            definition: definition,
            fixture: fixture,
            expected: expected
        )
    }
}
