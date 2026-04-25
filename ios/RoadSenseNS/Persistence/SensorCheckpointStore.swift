import Foundation

@MainActor
final class SensorCheckpointStore {
    private let fileURL: URL
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init(
        fileURL: URL? = nil,
        fileManager: FileManager = .default
    ) {
        if let fileURL {
            self.fileURL = fileURL
        } else {
            let baseURL = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            self.fileURL = baseURL.appendingPathComponent("SensorCheckpoint.json", isDirectory: false)
        }
        encoder.outputFormatting = [.sortedKeys]
    }

    func load(maxAge: TimeInterval, now: Date = Date()) throws -> SensorCheckpoint? {
        guard let data = try? Data(contentsOf: fileURL) else {
            return nil
        }

        let checkpoint = try decoder.decode(SensorCheckpoint.self, from: data)
        guard checkpoint.isFresh(at: now, maxAge: maxAge) else {
            try? clear()
            return nil
        }

        return checkpoint
    }

    func save(_ checkpoint: SensorCheckpoint) throws {
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let data = try encoder.encode(checkpoint)
        try data.write(to: fileURL, options: .atomic)
    }

    func clear() throws {
        if FileManager.default.fileExists(atPath: fileURL.path()) {
            try FileManager.default.removeItem(at: fileURL)
        }
    }
}
