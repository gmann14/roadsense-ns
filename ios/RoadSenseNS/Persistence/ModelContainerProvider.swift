import Foundation
import SwiftData

enum ModelContainerProvider {
    @MainActor
    static func schema() -> Schema {
        Schema(versionedSchema: RoadSenseSchemaV5.self)
    }

    @MainActor
    static func makeDefault() throws -> ModelContainer {
        let configuration = ModelConfiguration(
            schema: schema(),
            isStoredInMemoryOnly: false
        )
        return try ModelContainer(
            for: schema(),
            migrationPlan: RoadSenseSchemaMigrationPlan.self,
            configurations: [configuration]
        )
    }

    @MainActor
    static func makeInMemory() throws -> ModelContainer {
        let configuration = ModelConfiguration(
            schema: schema(),
            isStoredInMemoryOnly: true
        )
        return try ModelContainer(
            for: schema(),
            migrationPlan: RoadSenseSchemaMigrationPlan.self,
            configurations: [configuration]
        )
    }
}
