import Foundation

/// Actor-isolated JSON persistence with atomic file replacement.
/// On initialization, in-flight tasks are reconciled against their partial files
/// and moved to paused so they can be safely resumed after process termination.
public actor DownloadStore {
    private let fileURL: URL
    private var tasks: [UUID: DownloadTask]

    public init(fileURL: URL) throws {
        self.fileURL = fileURL
        var loaded: [UUID: DownloadTask]
        if FileManager.default.fileExists(atPath: fileURL.path) {
            let data = try Data(contentsOf: fileURL)
            let decoded = try JSONDecoder.zelto.decode([DownloadTask].self, from: data)
            loaded = [:]
            for task in decoded {
                if let existing = loaded[task.id], existing.updatedAt > task.updatedAt {
                    continue
                }
                // Prefer the newest durable snapshot if an older file contains
                // duplicate IDs instead of crashing during dictionary creation.
                loaded[task.id] = task
            }
        } else {
            loaded = [:]
        }

        var recovered = false
        for (id, var task) in loaded where task.status == .downloading {
            let partialURL = URL(fileURLWithPath: task.destinationPath)
            let attributes = try? FileManager.default.attributesOfItem(atPath: partialURL.path)
            let diskSize = (attributes?[.size] as? NSNumber)?.int64Value ?? 0

            if diskSize < 0 || (task.expectedBytes.map { diskSize > $0 } ?? false) {
                try? FileManager.default.removeItem(at: partialURL)
                task.bytesWritten = 0
                task.etag = nil
                task.lastModified = nil
                task.expectedBytes = nil
            } else {
                // The file is authoritative: a crash may occur after bytes hit disk
                // but before the latest progress metadata is atomically persisted.
                task.bytesWritten = diskSize
                if diskSize == 0 {
                    task.etag = nil
                    task.lastModified = nil
                }
            }
            task.status = .paused
            task.resumeData = nil
            task.updatedAt = Date()
            loaded[id] = task
            recovered = true
        }
        self.tasks = loaded

        if recovered {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let data = try JSONEncoder.zelto.encode(Array(loaded.values))
            try data.write(to: fileURL, options: .atomic)
        }
    }

    public func allTasks() -> [DownloadTask] {
        tasks.values.sorted { $0.createdAt < $1.createdAt }
    }

    public func task(id: UUID) -> DownloadTask? { tasks[id] }

    public func insert(_ task: DownloadTask) throws {
        guard tasks[task.id] == nil else { return }
        tasks[task.id] = task
        try persist()
    }

    @discardableResult
    public func update(id: UUID, _ change: (inout DownloadTask) throws -> Void) throws -> DownloadTask {
        guard var current = tasks[id] else { throw DownloadStoreError.taskNotFound }
        try change(&current)
        tasks[id] = current
        try persist()
        return current
    }

    public func remove(id: UUID) throws {
        tasks.removeValue(forKey: id)
        try persist()
    }

    private func persist() throws {
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        let data = try JSONEncoder.zelto.encode(Array(tasks.values))
        try data.write(to: fileURL, options: .atomic)
    }
}

public enum DownloadStoreError: Error { case taskNotFound }

private extension JSONEncoder {
    static var zelto: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }
}
private extension JSONDecoder {
    static var zelto: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
