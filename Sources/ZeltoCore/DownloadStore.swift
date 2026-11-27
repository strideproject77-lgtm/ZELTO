import Foundation

/// Actor-isolated JSON persistence with atomic file replacement.
public actor DownloadStore {
    private let fileURL: URL
    private var tasks: [UUID: DownloadTask]

    public init(fileURL: URL) throws {
        self.fileURL = fileURL
        if FileManager.default.fileExists(atPath: fileURL.path) {
            let data = try Data(contentsOf: fileURL)
            let decoded = try JSONDecoder.zelto.decode([DownloadTask].self, from: data)
            self.tasks = Dictionary(uniqueKeysWithValues: decoded.map { ($0.id, $0) })
        } else { self.tasks = [:] }
    }

    public func allTasks() -> [DownloadTask] { tasks.values.sorted { $0.createdAt < $1.createdAt } }
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
