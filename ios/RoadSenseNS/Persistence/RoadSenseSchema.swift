import Foundation
import SwiftData

enum RoadSenseSchemaV1: VersionedSchema {
    static var versionIdentifier: Schema.Version {
        Schema.Version(1, 0, 0)
    }

    static var models: [any PersistentModel.Type] {
        [
            ReadingRecord.self,
            UploadBatch.self,
            PrivacyZoneRecord.self,
            UserStats.self,
            DeviceTokenRecord.self,
        ]
    }
}

enum RoadSenseSchemaV2: VersionedSchema {
    static var versionIdentifier: Schema.Version {
        Schema.Version(2, 0, 0)
    }

    static var models: [any PersistentModel.Type] {
        [
            ReadingRecord.self,
            UploadBatch.self,
            PrivacyZoneRecord.self,
            UserStats.self,
            DeviceTokenRecord.self,
            PotholeActionRecord.self,
        ]
    }
}

enum RoadSenseSchemaV3: VersionedSchema {
    static var versionIdentifier: Schema.Version {
        Schema.Version(3, 0, 0)
    }

    static var models: [any PersistentModel.Type] {
        [
            ReadingRecord.self,
            UploadBatch.self,
            PrivacyZoneRecord.self,
            UserStats.self,
            DeviceTokenRecord.self,
            PotholeActionRecord.self,
            PotholeReportRecord.self,
        ]
    }
}

enum RoadSenseSchemaMigrationPlan: SchemaMigrationPlan {
    static var schemas: [any VersionedSchema.Type] {
        [RoadSenseSchemaV1.self, RoadSenseSchemaV2.self, RoadSenseSchemaV3.self]
    }

    static var stages: [MigrationStage] {
        [
            .lightweight(fromVersion: RoadSenseSchemaV1.self, toVersion: RoadSenseSchemaV2.self),
            .lightweight(fromVersion: RoadSenseSchemaV2.self, toVersion: RoadSenseSchemaV3.self),
        ]
    }
}
