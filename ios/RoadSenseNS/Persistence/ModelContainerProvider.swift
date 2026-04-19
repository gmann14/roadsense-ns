import Foundation
import SwiftData

enum ModelContainerProvider {
    @MainActor
    static func makeDefault() throws -> ModelContainer {
        let schema = Schema([
            ReadingRecord.self,
            UploadBatch.self,
            PrivacyZoneRecord.self,
            UserStats.self,
            DeviceTokenRecord.self,
        ])
        let configuration = ModelConfiguration(
            schema: schema,
            isStoredInMemoryOnly: false
        )
        return try ModelContainer(for: schema, configurations: [configuration])
    }
}
