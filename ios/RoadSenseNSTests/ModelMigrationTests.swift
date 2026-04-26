import Foundation
import SwiftData
import XCTest
@testable import RoadSense_NS

@MainActor
final class ModelMigrationTests: XCTestCase {
    func testMigratesLegacyV2PotholeActionsToCurrentSchema() throws {
        let directory = try makeTemporaryDirectory()
        let storeURL = directory.appendingPathComponent("default.store", isDirectory: false)
        let actionID = UUID(uuidString: "8D93538B-DDAE-4722-9D26-B72CB3D6391E")!
        let recordedAt = Date(timeIntervalSince1970: 1_777_159_663)

        do {
            let legacySchema = Schema(versionedSchema: RoadSenseSchemaV2.self)
            let legacyConfiguration = ModelConfiguration(
                schema: legacySchema,
                url: storeURL,
                allowsSave: true,
                cloudKitDatabase: .none
            )
            let legacyContainer = try ModelContainer(
                for: legacySchema,
                configurations: [legacyConfiguration]
            )
            let legacyContext = ModelContext(legacyContainer)
            legacyContext.insert(
                RoadSenseSchemaV2.PotholeActionRecord(
                    id: actionID,
                    actionTypeRawValue: PotholeActionType.manualReport.rawValue,
                    latitude: 44.4002817259187,
                    longitude: -64.312565470221,
                    accuracyM: 4.74865163977636,
                    recordedAt: recordedAt,
                    createdAt: recordedAt,
                    uploadStateRawValue: PotholeActionUploadState.pendingUpload.rawValue,
                    uploadAttemptCount: 4
                )
            )
            try legacyContext.save()
        }

        try assertMigratedLegacyPotholeAction(at: storeURL, actionID: actionID)
    }

    func testMigratesLegacyV3PotholeActionsToCurrentSchema() throws {
        let directory = try makeTemporaryDirectory()
        let storeURL = directory.appendingPathComponent("default.store", isDirectory: false)
        let actionID = UUID(uuidString: "8D93538B-DDAE-4722-9D26-B72CB3D6391E")!
        let recordedAt = Date(timeIntervalSince1970: 1_777_159_663)

        do {
            let legacySchema = Schema(versionedSchema: RoadSenseSchemaV3.self)
            let legacyConfiguration = ModelConfiguration(
                schema: legacySchema,
                url: storeURL,
                allowsSave: true,
                cloudKitDatabase: .none
            )
            let legacyContainer = try ModelContainer(
                for: legacySchema,
                configurations: [legacyConfiguration]
            )
            let legacyContext = ModelContext(legacyContainer)
            legacyContext.insert(
                RoadSenseSchemaV3.PotholeActionRecord(
                    id: actionID,
                    actionTypeRawValue: PotholeActionType.manualReport.rawValue,
                    latitude: 44.4002817259187,
                    longitude: -64.312565470221,
                    accuracyM: 4.74865163977636,
                    recordedAt: recordedAt,
                    createdAt: recordedAt,
                    uploadStateRawValue: PotholeActionUploadState.pendingUpload.rawValue,
                    uploadAttemptCount: 4
                )
            )
            try legacyContext.save()
        }

        try assertMigratedLegacyPotholeAction(at: storeURL, actionID: actionID)
    }

    func testMigratesLegacyV4PotholeActionsToCurrentSchema() throws {
        let directory = try makeTemporaryDirectory()
        let storeURL = directory.appendingPathComponent("default.store", isDirectory: false)
        let actionID = UUID(uuidString: "8D93538B-DDAE-4722-9D26-B72CB3D6391E")!
        let recordedAt = Date(timeIntervalSince1970: 1_777_159_663)

        do {
            let legacySchema = Schema(versionedSchema: RoadSenseSchemaV4.self)
            let legacyConfiguration = ModelConfiguration(
                schema: legacySchema,
                url: storeURL,
                allowsSave: true,
                cloudKitDatabase: .none
            )
            let legacyContainer = try ModelContainer(
                for: legacySchema,
                configurations: [legacyConfiguration]
            )
            let legacyContext = ModelContext(legacyContainer)
            legacyContext.insert(
                RoadSenseSchemaV4.PotholeActionRecord(
                    id: actionID,
                    actionTypeRawValue: PotholeActionType.manualReport.rawValue,
                    latitude: 44.4002817259187,
                    longitude: -64.312565470221,
                    accuracyM: 4.74865163977636,
                    recordedAt: recordedAt,
                    createdAt: recordedAt,
                    uploadStateRawValue: PotholeActionUploadState.pendingUpload.rawValue,
                    uploadAttemptCount: 4
                )
            )
            try legacyContext.save()
        }

        try assertMigratedLegacyPotholeAction(at: storeURL, actionID: actionID)
    }

    func testRecoveryBacksUpUnreadablePersistentStoreAndCreatesFreshStore() throws {
        let directory = try makeTemporaryDirectory()
        let storeURL = directory.appendingPathComponent("default.store", isDirectory: false)
        try Data("not a sqlite store".utf8).write(to: storeURL)

        let recoveredContainer = try ModelContainerProvider.makePersistentStore(
            at: storeURL,
            recoveryStrategy: .backupAndReset
        )
        let recoveredContext = ModelContext(recoveredContainer)
        let recoveredActions = try recoveredContext.fetch(FetchDescriptor<PotholeActionRecord>())
        let backupRoot = directory.appendingPathComponent("RecoveredStores", isDirectory: true)
        let backupFiles = try FileManager.default
            .subpathsOfDirectory(atPath: backupRoot.path)
            .filter { $0.hasSuffix("default.store") }

        XCTAssertTrue(recoveredActions.isEmpty)
        XCTAssertEqual(backupFiles.count, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: storeURL.path))
    }

    private func makeTemporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("RoadSenseNSMigrationTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: directory)
        }
        return directory
    }

    private func assertMigratedLegacyPotholeAction(at storeURL: URL, actionID: UUID) throws {
        let migratedContainer = try ModelContainerProvider.makePersistentStore(at: storeURL)
        let migratedContext = ModelContext(migratedContainer)
        let migratedRecords = try migratedContext.fetch(FetchDescriptor<PotholeActionRecord>())

        XCTAssertEqual(migratedRecords.count, 1)
        XCTAssertEqual(migratedRecords.first?.id, actionID)
        XCTAssertEqual(migratedRecords.first?.actionType, .manualReport)
        XCTAssertEqual(migratedRecords.first?.uploadState, .pendingUpload)
        XCTAssertNil(migratedRecords.first?.sensorBackedMagnitudeG)
        XCTAssertNil(migratedRecords.first?.sensorBackedAt)
    }
}
