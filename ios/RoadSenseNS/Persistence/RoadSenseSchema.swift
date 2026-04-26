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

    @Model
    final class PotholeActionRecord {
        @Attribute(.unique) var id: UUID
        var potholeReportID: UUID?
        var actionTypeRawValue: String
        var latitude: Double
        var longitude: Double
        var accuracyM: Double
        var recordedAt: Date
        var createdAt: Date
        var undoExpiresAt: Date?
        var uploadStateRawValue: String
        var uploadAttemptCount: Int
        var lastAttemptAt: Date?
        var nextAttemptAt: Date?
        var lastHTTPStatusCode: Int?
        var lastRequestID: String?

        init(
            id: UUID = UUID(),
            potholeReportID: UUID? = nil,
            actionTypeRawValue: String,
            latitude: Double,
            longitude: Double,
            accuracyM: Double,
            recordedAt: Date,
            createdAt: Date,
            undoExpiresAt: Date? = nil,
            uploadStateRawValue: String,
            uploadAttemptCount: Int = 0,
            lastAttemptAt: Date? = nil,
            nextAttemptAt: Date? = nil,
            lastHTTPStatusCode: Int? = nil,
            lastRequestID: String? = nil
        ) {
            self.id = id
            self.potholeReportID = potholeReportID
            self.actionTypeRawValue = actionTypeRawValue
            self.latitude = latitude
            self.longitude = longitude
            self.accuracyM = accuracyM
            self.recordedAt = recordedAt
            self.createdAt = createdAt
            self.undoExpiresAt = undoExpiresAt
            self.uploadStateRawValue = uploadStateRawValue
            self.uploadAttemptCount = uploadAttemptCount
            self.lastAttemptAt = lastAttemptAt
            self.nextAttemptAt = nextAttemptAt
            self.lastHTTPStatusCode = lastHTTPStatusCode
            self.lastRequestID = lastRequestID
        }
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

    @Model
    final class PotholeActionRecord {
        @Attribute(.unique) var id: UUID
        var potholeReportID: UUID?
        var actionTypeRawValue: String
        var latitude: Double
        var longitude: Double
        var accuracyM: Double
        var recordedAt: Date
        var createdAt: Date
        var undoExpiresAt: Date?
        var uploadStateRawValue: String
        var uploadAttemptCount: Int
        var lastAttemptAt: Date?
        var nextAttemptAt: Date?
        var lastHTTPStatusCode: Int?
        var lastRequestID: String?

        init(
            id: UUID = UUID(),
            potholeReportID: UUID? = nil,
            actionTypeRawValue: String,
            latitude: Double,
            longitude: Double,
            accuracyM: Double,
            recordedAt: Date,
            createdAt: Date,
            undoExpiresAt: Date? = nil,
            uploadStateRawValue: String,
            uploadAttemptCount: Int = 0,
            lastAttemptAt: Date? = nil,
            nextAttemptAt: Date? = nil,
            lastHTTPStatusCode: Int? = nil,
            lastRequestID: String? = nil
        ) {
            self.id = id
            self.potholeReportID = potholeReportID
            self.actionTypeRawValue = actionTypeRawValue
            self.latitude = latitude
            self.longitude = longitude
            self.accuracyM = accuracyM
            self.recordedAt = recordedAt
            self.createdAt = createdAt
            self.undoExpiresAt = undoExpiresAt
            self.uploadStateRawValue = uploadStateRawValue
            self.uploadAttemptCount = uploadAttemptCount
            self.lastAttemptAt = lastAttemptAt
            self.nextAttemptAt = nextAttemptAt
            self.lastHTTPStatusCode = lastHTTPStatusCode
            self.lastRequestID = lastRequestID
        }
    }
}

enum RoadSenseSchemaV4: VersionedSchema {
    static var versionIdentifier: Schema.Version {
        Schema.Version(4, 0, 0)
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
            DriveSessionRecord.self,
        ]
    }

    @Model
    final class PotholeActionRecord {
        @Attribute(.unique) var id: UUID
        var potholeReportID: UUID?
        var actionTypeRawValue: String
        var latitude: Double
        var longitude: Double
        var accuracyM: Double
        var recordedAt: Date
        var createdAt: Date
        var undoExpiresAt: Date?
        var uploadStateRawValue: String
        var uploadAttemptCount: Int
        var lastAttemptAt: Date?
        var nextAttemptAt: Date?
        var lastHTTPStatusCode: Int?
        var lastRequestID: String?

        init(
            id: UUID = UUID(),
            potholeReportID: UUID? = nil,
            actionTypeRawValue: String,
            latitude: Double,
            longitude: Double,
            accuracyM: Double,
            recordedAt: Date,
            createdAt: Date,
            undoExpiresAt: Date? = nil,
            uploadStateRawValue: String,
            uploadAttemptCount: Int = 0,
            lastAttemptAt: Date? = nil,
            nextAttemptAt: Date? = nil,
            lastHTTPStatusCode: Int? = nil,
            lastRequestID: String? = nil
        ) {
            self.id = id
            self.potholeReportID = potholeReportID
            self.actionTypeRawValue = actionTypeRawValue
            self.latitude = latitude
            self.longitude = longitude
            self.accuracyM = accuracyM
            self.recordedAt = recordedAt
            self.createdAt = createdAt
            self.undoExpiresAt = undoExpiresAt
            self.uploadStateRawValue = uploadStateRawValue
            self.uploadAttemptCount = uploadAttemptCount
            self.lastAttemptAt = lastAttemptAt
            self.nextAttemptAt = nextAttemptAt
            self.lastHTTPStatusCode = lastHTTPStatusCode
            self.lastRequestID = lastRequestID
        }
    }
}

enum RoadSenseSchemaV5: VersionedSchema {
    static var versionIdentifier: Schema.Version {
        Schema.Version(5, 0, 0)
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
            DriveSessionRecord.self,
        ]
    }
}

enum RoadSenseSchemaMigrationPlan: SchemaMigrationPlan {
    static var schemas: [any VersionedSchema.Type] {
        [
            RoadSenseSchemaV1.self,
            RoadSenseSchemaV2.self,
            RoadSenseSchemaV3.self,
            RoadSenseSchemaV4.self,
            RoadSenseSchemaV5.self,
        ]
    }

    static var stages: [MigrationStage] {
        [
            .lightweight(fromVersion: RoadSenseSchemaV1.self, toVersion: RoadSenseSchemaV2.self),
            .lightweight(fromVersion: RoadSenseSchemaV2.self, toVersion: RoadSenseSchemaV3.self),
            .lightweight(fromVersion: RoadSenseSchemaV3.self, toVersion: RoadSenseSchemaV4.self),
            .lightweight(fromVersion: RoadSenseSchemaV4.self, toVersion: RoadSenseSchemaV5.self),
        ]
    }
}
