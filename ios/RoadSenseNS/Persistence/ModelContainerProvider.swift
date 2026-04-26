import Foundation
import SwiftData

enum PersistentStoreRecoveryStrategy: Equatable {
    case disabled
    case backupAndReset
}

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
        return try makePersistentStore(
            configuration: configuration,
            recoveryStrategy: .backupAndReset
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

    @MainActor
    static func makePersistentStore(
        at storeURL: URL,
        recoveryStrategy: PersistentStoreRecoveryStrategy = .disabled
    ) throws -> ModelContainer {
        let configuration = ModelConfiguration(
            schema: schema(),
            url: storeURL,
            allowsSave: true,
            cloudKitDatabase: .none
        )
        return try makePersistentStore(
            configuration: configuration,
            recoveryStrategy: recoveryStrategy
        )
    }

    @MainActor
    private static func makePersistentStore(
        configuration: ModelConfiguration,
        recoveryStrategy: PersistentStoreRecoveryStrategy
    ) throws -> ModelContainer {
        do {
            return try makeContainer(configuration: configuration)
        } catch {
            guard recoveryStrategy == .backupAndReset else {
                throw error
            }

            try PersistentStoreRecovery.backupAndRemoveStore(at: configuration.url)
            return try makeContainer(configuration: configuration)
        }
    }

    @MainActor
    private static func makeContainer(configuration: ModelConfiguration) throws -> ModelContainer {
        try ModelContainer(
            for: schema(),
            migrationPlan: RoadSenseSchemaMigrationPlan.self,
            configurations: [configuration]
        )
    }
}

enum PersistentStoreRecovery {
    static func backupAndRemoveStore(
        at storeURL: URL,
        fileManager: FileManager = .default,
        now: Date = Date()
    ) throws {
        let existingFiles = storeFileSet(for: storeURL).filter {
            fileManager.fileExists(atPath: $0.path)
        }

        guard !existingFiles.isEmpty else {
            return
        }

        let backupDirectory = storeURL
            .deletingLastPathComponent()
            .appendingPathComponent("RecoveredStores", isDirectory: true)
            .appendingPathComponent(backupDirectoryName(now: now), isDirectory: true)
        try fileManager.createDirectory(at: backupDirectory, withIntermediateDirectories: true)

        for fileURL in existingFiles {
            try fileManager.moveItem(
                at: fileURL,
                to: backupDirectory.appendingPathComponent(fileURL.lastPathComponent, isDirectory: false)
            )
        }
    }

    private static func storeFileSet(for storeURL: URL) -> [URL] {
        [
            storeURL,
            URL(fileURLWithPath: storeURL.path + "-shm"),
            URL(fileURLWithPath: storeURL.path + "-wal"),
        ]
    }

    private static func backupDirectoryName(now: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: now)
            .replacingOccurrences(of: ":", with: "-")
            .appending("-\(UUID().uuidString)")
    }
}
