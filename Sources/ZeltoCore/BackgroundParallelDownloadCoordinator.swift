#if os(iOS)
import Foundation

/// System-managed, multi-connection downloader for large files.
/// Each byte range is a separate background URLSessionDownloadTask, so iOS
/// can continue the transfers while the host app is suspended or terminated.
public final class BackgroundParallelDownloadCoordinator: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    public static let defaultIdentifier = "com.ahmiidev.zelto.background-parallel"

    private struct Manifest: Codable {
        let version: Int
        let sourceURL: String
        let destinationPath: String
        let totalBytes: Int64
        let etag: String?
        let lastModified: String?
        let ranges: [HTTPByteRange]
        var completed: Set<Int>
    }

    private struct TaskMetadata: Codable {
        let taskID: UUID
        let destinationPath: String
        let directoryPath: String
        let index: Int
        let lowerBound: Int64
        let upperBound: Int64
        let totalBytes: Int64
        let validator: String
    }

    private let store: DownloadStore
    private let identifier: String
    private let lock = NSLock()
    private var session: URLSession!
    private var completionHandler: (() -> Void)?
    private var inFlightBytes: [UUID: [Int: Int64]] = [:]
    private var responseResults: [Int: (status: Int, valid: Bool)] = [:]
    private var pausingIDs: Set<UUID> = []
    private var deletingIDs: Set<UUID> = []
    private var mergingIDs: Set<UUID> = []
    private let onProgress: (@Sendable (UUID) -> Void)?

    public init(store: DownloadStore,
                identifier: String = BackgroundParallelDownloadCoordinator.defaultIdentifier,
                onProgress: (@Sendable (UUID) -> Void)? = nil) {
        self.store = store
        self.identifier = identifier
        self.onProgress = onProgress
        super.init()
        let configuration = URLSessionConfiguration.background(withIdentifier: identifier)
        configuration.sessionSendsLaunchEvents = true
        configuration.isDiscretionary = false
        configuration.waitsForConnectivity = true
        configuration.httpMaximumConnectionsPerHost = 8
        self.session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
    }

    /// Returns nil when safe multi-range downloading is unavailable.
    @discardableResult
    public func enqueue(task: DownloadTask) async throws -> Int? {
        let existing = await allTasks()
        if let active = existing.first(where: {
            Self.metadata(from: $0.taskDescription)?.taskID == task.id
        }) {
            return active.taskIdentifier
        }

        guard let identity = try? await probe(task.sourceURL),
              identity.totalBytes >= ParallelHTTPDownloadClient.defaultMinimumFileSize,
              let validator = identity.validator,
              let ranges = HTTPRangePlanner.makePlan(totalBytes: identity.totalBytes,
                                                     preferredConnections: 4) else {
            return nil
        }
        if let expected = task.expectedBytes, expected > 0, expected != identity.totalBytes {
            return nil
        }

        let destination = URL(fileURLWithPath: task.destinationPath)
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        let directory = destination.deletingLastPathComponent()
            .appendingPathComponent(".zelto-\(task.id.uuidString.lowercased()).background-segments",
                                    isDirectory: true)
        let manifestURL = directory.appendingPathComponent("manifest.json")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        var manifest = loadManifest(at: manifestURL, task: task, identity: identity, ranges: ranges)
        if manifest == nil {
            try? FileManager.default.removeItem(at: directory)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            manifest = Manifest(version: 1, sourceURL: task.sourceURL.absoluteString,
                                destinationPath: task.destinationPath, totalBytes: identity.totalBytes,
                                etag: identity.etag, lastModified: identity.lastModified,
                                ranges: ranges, completed: [])
        }
        guard var current = manifest else { return nil }

        for range in ranges where current.completed.contains(range.index) {
            if fileSize(segmentURL(range.index, directory: directory)) != range.byteCount {
                current.completed.remove(range.index)
                try? FileManager.default.removeItem(at: segmentURL(range.index, directory: directory))
            }
        }
        try persist(current, to: manifestURL)

        let durableBytes = current.ranges.filter { current.completed.contains($0.index) }
            .reduce(Int64(0)) { $0 + $1.byteCount }
        _ = try? await store.update(id: task.id) { value in
            guard value.status == .downloading else { return }
            value.bytesWritten = durableBytes
            value.expectedBytes = identity.totalBytes
            value.etag = identity.etag
            value.lastModified = identity.lastModified
            value.resumeData = nil
        }

        let pending = ranges.filter { !current.completed.contains($0.index) }
        guard !pending.isEmpty else {
            try finishMerge(manifest: current, directory: directory, destination: destination)
            await markCompleted(taskID: task.id, destination: destination, total: identity.totalBytes)
            return -1
        }

        var firstIdentifier: Int?
        for range in pending {
            var request = URLRequest(url: task.sourceURL)
            request.httpMethod = "GET"
            request.timeoutInterval = 120
            request.setValue("bytes=\(range.lowerBound)-\(range.upperBound)", forHTTPHeaderField: "Range")
            request.setValue(validator, forHTTPHeaderField: "If-Range")
            request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
            let download = session.downloadTask(with: request)
            let metadata = TaskMetadata(taskID: task.id, destinationPath: task.destinationPath,
                                        directoryPath: directory.path, index: range.index,
                                        lowerBound: range.lowerBound, upperBound: range.upperBound,
                                        totalBytes: identity.totalBytes, validator: validator)
            download.taskDescription = Self.encode(metadata)
            if firstIdentifier == nil { firstIdentifier = download.taskIdentifier }
            download.resume()
        }
        onProgress?(task.id)
        return firstIdentifier
    }

    public func hasActiveTask(id: UUID) async -> Bool {
        await allTasks().contains { Self.metadata(from: $0.taskDescription)?.taskID == id }
    }

    public func pause(id: UUID) async {
        let tasks = await allTasks().filter { Self.metadata(from: $0.taskDescription)?.taskID == id }
        lock.withLock { pausingIDs.insert(id) }
        for task in tasks { task.cancel() }
        let saved = await store.task(id: id)
        let durable = saved.map { durableByteCount(for: $0) } ?? 0
        _ = try? await store.update(id: id) { value in
            if value.status == .downloading {
                value.bytesWritten = durable
                try value.pause()
            }
        }
        lock.withLock {
            pausingIDs.remove(id)
            inFlightBytes.removeValue(forKey: id)
        }
        onProgress?(id)
    }

    public func delete(id: UUID) async {
        let tasks = await allTasks().filter { Self.metadata(from: $0.taskDescription)?.taskID == id }
        lock.withLock { deletingIDs.insert(id) }
        for task in tasks { task.cancel() }
        if let saved = await store.task(id: id) {
            let destination = URL(fileURLWithPath: saved.destinationPath)
            let directory = segmentDirectory(for: saved)
            try? FileManager.default.removeItem(at: directory)
            try? FileManager.default.removeItem(at: destination.appendingPathExtension("zelto-merging"))
        }
        lock.withLock {
            deletingIDs.remove(id)
            inFlightBytes.removeValue(forKey: id)
        }
    }

    public func handleEvents(identifier: String, completionHandler: @escaping () -> Void) {
        guard identifier == self.identifier else { completionHandler(); return }
        lock.withLock { self.completionHandler = completionHandler }
    }

    public func reconcileAfterRelaunch() async {
        let active = await allTasks()
        let ids = Set(active.compactMap { Self.metadata(from: $0.taskDescription)?.taskID })
        for id in ids {
            _ = try? await store.update(id: id) { value in
                if value.status == .paused { try value.start() }
            }
            if let task = await store.task(id: id) { onProgress?(task.id) }
        }
    }

    private func allTasks() async -> [URLSessionDownloadTask] {
        await withCheckedContinuation { continuation in
            session.getTasksWithCompletionHandler { _, _, downloads in
                continuation.resume(returning: downloads)
            }
        }
    }

    public func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                           didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
                           totalBytesExpectedToWrite: Int64) {
        guard let metadata = Self.metadata(from: downloadTask.taskDescription) else { return }
        guard !lock.withLock({ deletingIDs.contains(metadata.taskID) || pausingIDs.contains(metadata.taskID) }) else { return }
        lock.withLock {
            inFlightBytes[metadata.taskID, default: [:]][metadata.index] = totalBytesWritten
        }
        let durable = durableByteCount(metadata: metadata)
        let live = lock.withLock {
            (inFlightBytes[metadata.taskID] ?? [:]).values.reduce(Int64(0), +)
        }
        let aggregate = min(metadata.totalBytes, durable + live)
        let store = self.store
        updates.enqueue {
            _ = try? await store.update(id: metadata.taskID) { value in
                guard value.status == .downloading else { return }
                value.bytesWritten = aggregate
                value.expectedBytes = metadata.totalBytes
            }
            self.onProgress?(metadata.taskID)
        }
    }

    public func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                           didFinishDownloadingTo location: URL) {
        guard let metadata = Self.metadata(from: downloadTask.taskDescription) else { return }
        if lock.withLock({ deletingIDs.contains(metadata.taskID) }) {
            try? FileManager.default.removeItem(at: location)
            return
        }
        let directory = URL(fileURLWithPath: metadata.directoryPath, isDirectory: true)
        let part = segmentURL(metadata.index, directory: directory)
        guard let response = downloadTask.response as? HTTPURLResponse,
              response.statusCode == 206,
              let raw = response.value(forHTTPHeaderField: "Content-Range"),
              let parsed = HTTPRangePlanner.parseContentRange(raw),
              parsed.start == metadata.lowerBound,
              parsed.end == metadata.upperBound,
              parsed.total == metadata.totalBytes,
              response.value(forHTTPHeaderField: "ETag") == metadata.validator
                || response.value(forHTTPHeaderField: "Last-Modified") == metadata.validator,
              fileSize(location) == metadata.upperBound - metadata.lowerBound + 1 else {
            try? FileManager.default.removeItem(at: location)
            lock.withLock { responseResults[downloadTask.taskIdentifier] = (status: responseStatus(downloadTask), valid: false) }
            cancelSiblings(for: metadata.taskID, excluding: downloadTask.taskIdentifier)
            return
        }

        do {
            try? FileManager.default.removeItem(at: part)
            try FileManager.default.moveItem(at: location, to: part)
            let manifestURL = directory.appendingPathComponent("manifest.json")
            guard var manifest = try? JSONDecoder().decode(Manifest.self, from: Data(contentsOf: manifestURL)) else {
                throw BackgroundParallelError.manifestUnavailable
            }
            manifest.completed.insert(metadata.index)
            try persist(manifest, to: manifestURL)
            lock.withLock {
                inFlightBytes[metadata.taskID]?.removeValue(forKey: metadata.index)
                responseResults[downloadTask.taskIdentifier] = (status: 206, valid: true)
            }
            let bytes = durableByteCount(manifest: manifest)
            let store = self.store
            updates.enqueue {
                _ = try? await store.update(id: metadata.taskID) { value in
                    guard value.status == .downloading else { return }
                    value.bytesWritten = bytes
                    value.expectedBytes = manifest.totalBytes
                    value.etag = manifest.etag
                    value.lastModified = manifest.lastModified
                }
                self.onProgress?(metadata.taskID)
            }

            if manifest.completed.count == manifest.ranges.count,
               !lock.withLock({ mergingIDs.contains(metadata.taskID) || pausingIDs.contains(metadata.taskID) }) {
                lock.withLock { mergingIDs.insert(metadata.taskID) }
                let destination = URL(fileURLWithPath: metadata.destinationPath)
                do {
                    try finishMerge(manifest: manifest, directory: directory, destination: destination)
                    Task { await markCompleted(taskID: metadata.taskID, destination: destination, total: manifest.totalBytes) }
                } catch {
                    Task { await markFailed(taskID: metadata.taskID, message: "Segments could not be safely merged: \(error.localizedDescription)") }
                }
            }
        } catch {
            try? FileManager.default.removeItem(at: location)
            lock.withLock { responseResults[downloadTask.taskIdentifier] = (status: 206, valid: false) }
            cancelSiblings(for: metadata.taskID, excluding: downloadTask.taskIdentifier)
        }
    }

    public func urlSession(_ session: URLSession, task: URLSessionTask,
                           didCompleteWithError error: Error?) {
        guard let metadata = Self.metadata(from: task.taskDescription) else { return }
        let result = lock.withLock {
            responseResults.removeValue(forKey: task.taskIdentifier)
        }
        if lock.withLock({ deletingIDs.contains(metadata.taskID) || pausingIDs.contains(metadata.taskID) }) { return }
        if error != nil || result?.valid != true {
            cancelSiblings(for: metadata.taskID, excluding: task.taskIdentifier)
            Task {
                let durable = await self.durableByteCount(for: metadata.taskID)
                _ = try? await store.update(id: metadata.taskID) { value in
                    guard value.status == .downloading else { return }
                    value.bytesWritten = durable
                    try value.pause()
                }
                onProgress?(metadata.taskID)
            }
        }
    }

    public func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        let handler = lock.withLock { () -> (() -> Void)? in
            let value = completionHandler
            completionHandler = nil
            return value
        }
        if let handler { DispatchQueue.main.async(execute: handler) }
    }

    private func probe(_ url: URL) async throws -> BackgroundResourceIdentity {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 30
        request.setValue("bytes=0-0", forHTTPHeaderField: "Range")
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 206,
              data.count == 1,
              let raw = http.value(forHTTPHeaderField: "Content-Range"),
              let parsed = HTTPRangePlanner.parseContentRange(raw),
              parsed.start == 0, parsed.end == 0 else {
            throw BackgroundParallelError.rangeUnsupported
        }
        return BackgroundResourceIdentity(totalBytes: parsed.total,
                                           etag: http.value(forHTTPHeaderField: "ETag"),
                                           lastModified: http.value(forHTTPHeaderField: "Last-Modified"))
    }

    private func loadManifest(at url: URL, task: DownloadTask, identity: BackgroundResourceIdentity,
                              ranges: [HTTPByteRange]) -> Manifest? {
        guard let data = try? Data(contentsOf: url),
              let value = try? JSONDecoder().decode(Manifest.self, from: data),
              value.version == 1, value.sourceURL == task.sourceURL.absoluteString,
              value.destinationPath == task.destinationPath, value.totalBytes == identity.totalBytes,
              value.etag == identity.etag, value.lastModified == identity.lastModified,
              value.ranges == ranges else { return nil }
        return value
    }

    private func persist(_ manifest: Manifest, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(manifest).write(to: url, options: .atomic)
    }

    private func finishMerge(manifest: Manifest, directory: URL, destination: URL) throws {
        let staging = destination.appendingPathExtension("zelto-merging")
        try? FileManager.default.removeItem(at: staging)
        guard FileManager.default.createFile(atPath: staging.path, contents: nil) else {
            throw BackgroundParallelError.stagingUnavailable
        }
        let output = try FileHandle(forWritingTo: staging)
        do {
            for range in manifest.ranges.sorted(by: { $0.index < $1.index }) {
                let part = segmentURL(range.index, directory: directory)
                guard fileSize(part) == range.byteCount else {
                    throw BackgroundParallelError.segmentSizeMismatch
                }
                let input = try FileHandle(forReadingFrom: part)
                defer { try? input.close() }
                while let data = try input.read(upToCount: 1024 * 1024), !data.isEmpty {
                    try output.write(contentsOf: data)
                }
            }
            try output.synchronize()
            try output.close()
            guard fileSize(staging) == manifest.totalBytes else {
                throw BackgroundParallelError.finalSizeMismatch
            }
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.moveItem(at: staging, to: destination)
            try? FileManager.default.removeItem(at: directory)
        } catch {
            try? output.close()
            try? FileManager.default.removeItem(at: staging)
            throw error
        }
    }

    private func markCompleted(taskID: UUID, destination: URL, total: Int64) async {
        _ = try? await store.update(id: taskID) { value in
            guard value.status == .downloading else { return }
            value.bytesWritten = total
            value.expectedBytes = total
            try value.complete(actualBytes: total)
        }
        lock.withLock {
            inFlightBytes.removeValue(forKey: taskID)
            mergingIDs.remove(taskID)
        }
        onProgress?(taskID)
    }

    private func markFailed(taskID: UUID, message: String) async {
        _ = try? await store.update(id: taskID) { value in
            if value.status == .downloading { try value.markFailed(message: message) }
        }
        lock.withLock { mergingIDs.remove(taskID) }
        onProgress?(taskID)
    }

    private func cancelSiblings(for id: UUID, excluding taskIdentifier: Int) {
        Task {
            let siblings = await allTasks().filter {
                $0.taskIdentifier != taskIdentifier &&
                Self.metadata(from: $0.taskDescription)?.taskID == id
            }
            for task in siblings { task.cancel() }
        }
    }

    private func durableByteCount(for task: DownloadTask) -> Int64 {
        let directory = segmentDirectory(for: task)
        guard let manifest = try? JSONDecoder().decode(
            Manifest.self, from: Data(contentsOf: directory.appendingPathComponent("manifest.json"))
        ) else { return 0 }
        return durableByteCount(manifest: manifest)
    }

    private func durableByteCount(metadata: TaskMetadata) -> Int64 {
        let directory = URL(fileURLWithPath: metadata.directoryPath, isDirectory: true)
        guard let manifest = try? JSONDecoder().decode(
            Manifest.self, from: Data(contentsOf: directory.appendingPathComponent("manifest.json"))
        ) else { return 0 }
        return durableByteCount(manifest: manifest)
    }

    private func durableByteCount(manifest: Manifest) -> Int64 {
        manifest.ranges.filter { manifest.completed.contains($0.index) }
            .reduce(Int64(0)) { $0 + $1.byteCount }
    }

    private func segmentDirectory(for task: DownloadTask) -> URL {
        URL(fileURLWithPath: task.destinationPath).deletingLastPathComponent()
            .appendingPathComponent(".zelto-\(task.id.uuidString.lowercased()).background-segments",
                                    isDirectory: true)
    }

    private func segmentURL(_ index: Int, directory: URL) -> URL {
        directory.appendingPathComponent("segment-\(index).part")
    }

    private func fileSize(_ url: URL) -> Int64 {
        ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? NSNumber)?.int64Value ?? -1
    }

    private func responseStatus(_ task: URLSessionTask) -> Int {
        (task.response as? HTTPURLResponse)?.statusCode ?? 0
    }

    private static func encode(_ metadata: TaskMetadata) -> String? {
        guard let data = try? JSONEncoder().encode(metadata) else { return nil }
        return "zelto-parallel:" + data.base64EncodedString()
    }

    private static func metadata(from description: String?) -> TaskMetadata? {
        guard let description, description.hasPrefix("zelto-parallel:"),
              let data = Data(base64Encoded: String(description.dropFirst("zelto-parallel:".count))) else { return nil }
        return try? JSONDecoder().decode(TaskMetadata.self, from: data)
    }

    private let updates = BackgroundParallelStoreQueue()
}

private struct BackgroundResourceIdentity {
    let totalBytes: Int64
    let etag: String?
    let lastModified: String?
    var validator: String? {
        if let etag, !etag.hasPrefix("W/") { return etag }
        return lastModified
    }
}

private enum BackgroundParallelError: Error {
    case rangeUnsupported, manifestUnavailable, stagingUnavailable
    case segmentSizeMismatch, finalSizeMismatch
}

private final class BackgroundParallelStoreQueue: @unchecked Sendable {
    private let lock = NSLock()
    private var tail: Task<Void, Never>?
    func enqueue(_ operation: @escaping @Sendable () async -> Void) {
        lock.lock()
        let previous = tail
        tail = Task { await previous?.value; await operation() }
        lock.unlock()
    }
}

private extension BackgroundParallelDownloadCoordinator {
    func durableByteCount(for id: UUID) async -> Int64 {
        guard let task = await store.task(id: id) else { return 0 }
        return durableByteCount(for: task)
    }
}
#endif
