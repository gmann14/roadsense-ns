import Foundation
import SwiftData

enum ModelContainerProvider {
    @MainActor
    static func schema() -> Schema {
        Schema([
            ReadingRecord.self,
            UploadBatch.self,
            PrivacyZoneRecord.self,
            UserStats.self,
            DeviceTokenRecord.self,
        ])
    }

    @MainActor
    static func makeDefault() throws -> ModelContainer {
        let configuration = ModelConfiguration(
            schema: schema(),
            isStoredInMemoryOnly: false
        )
        return try ModelContainer(for: schema(), configurations: [configuration])
    }

    @MainActor
    static func makeInMemory() throws -> ModelContainer {
        let configuration = ModelConfiguration(
            schema: schema(),
            isStoredInMemoryOnly: true
        )
        return try ModelContainer(for: schema(), configurations: [configuration])
    }
}
