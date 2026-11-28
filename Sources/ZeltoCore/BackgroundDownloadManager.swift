#if os(iOS)
import Foundation

/// Owns a system-managed background URLSession download queue.
///
/// The host app must forward
/// `application(_:handleEventsForBackgroundURLSession:completionHandler:)`
/// to `handleEventsForBackgroundURLSession(identifier:completionHandler:)`.
/// Keep the manager alive for the app lifetime and keep its identifier stable.
public final class BackgroundDownloadManager: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    public static let defaultIdentifier = "com.ahmiidev.zelto.background-downloads"

    private let store: DownloadStore
    private let identifier: String
    private let lock = NSLock()
    private var session: URLSession!
    private var backgroundEventsCompletion: (() -> Void)?
    private var fileMoveResults: [UUID: Bool] = [:]
    private var fileResponseResults: [UUID: (statusCode: Int, expectedBytes: Int64?)] = [:]
    private var pausingTaskIDs: Set<UUID> = []
    private var deletingTaskIDs: Set<UUID> = []
    private let updates = BackgroundStoreUpdateQueue()

    public init(store: DownloadStore, identifier: String = BackgroundDownloadManager.defaultIdentifier) {
        self.store = store
        self.identifier = identifier
        super.init()

        let configuration = URLSessionConfiguration.background(withIdentifier: identifier)
        configuration.sessionSendsLaunchEvents = true
        configuration.isDiscretionary = false
        configuration.waitsForConnectivity = true
        self.session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
    }

    /// Starts a queued/paused task using iOS-managed background downloading.
    /// Existing URLSession resume data is preferred when available.
    @discardableResult
    public func enqueue(id: UUID) async throws -> Int {
        // Reuse a transfer already owned by the background daemon. This avoids
        // creating duplicate downloads when the UI is opened before relaunch
        // reconciliation has finished.
        let existingTasks = await allDownloadTasks()
        if let existing = existingTasks.first(where: {
            Self.parseTaskDescription($0.taskDescription)?.id == id
        }) {
            if let saved = await store.task(id: id),
               saved.status == .paused || saved.status == .queued {
                _ = try? await store.update(id: id) { value in
                    if value.status == .paused || value.status == .queued {
                        try value.start()
                    }
                }
            }
            return existing.taskIdentifier
        }

        guard let saved = await store.task(id: id) else { throw DownloadStoreError.taskNotFound }
        if saved.status == .failed {
            _ = try await store.update(id: id) { try $0.retry() }
        }
        let active = try await store.update(id: id) { try $0.start() }

        let downloadTask: URLSessionDownloadTask
        if let resumeData = active.resumeData, !resumeData.isEmpty {
            downloadTask = session.downloadTask(withResumeData: resumeData)
        } else {
            downloadTask = session.downloadTask(with: active.sourceURL)
        }
        downloadTask.taskDescription = Self.makeTaskDescription(id: id, destinationPath: active.destinationPath)
        downloadTask.resume()
        return downloadTask.taskIdentifier
    }

    /// Cancels an active transfer, removes its saved metadata, and deletes
    /// the destination file. Late URLSession callbacks are ignored for this ID.
    public func delete(id: UUID) async throws {
        guard let saved = await store.task(id: id) else { throw DownloadStoreError.taskNotFound }
        let tasks = await allDownloadTasks()
        if let active = tasks.first(where: { Self.parseTaskDescription($0.taskDescription)?.id == id }) {
            lock.withLock { deletingTaskIDs.insert(id) }
            active.cancel()
        }
        try await store.remove(id: id)
        if FileManager.default.fileExists(atPath: saved.destinationPath) {
            try FileManager.default.removeItem(atPath: saved.destinationPath)
        }
    }

    /// Requests a cooperative pause. iOS may provide opaque resume data; if it
    /// does not, the next enqueue safely restarts using a fresh request.
    public func pause(id: UUID) async throws {
        let tasks = await allDownloadTasks()
        guard let task = tasks.first(where: { Self.parseTaskDescription($0.taskDescription)?.id == id }) else {
            _ = try await store.update(id: id) { value in
                if value.status == .downloading { try value.pause() }
            }
            return
        }

        lock.withLock { pausingTaskIDs.insert(id) }
        await withCheckedContinuation { continuation in
            task.cancel { [weak self] resumeData in
                guard let self else { continuation.resume(); return }
                Task {
                    _ = try? await self.store.update(id: id) { value in
                        if value.status == .downloading { try value.pause(resumeData: resumeData) }
                    }
                    self.lock.withLock { self.pausingTaskIDs.remove(id) }
                    continuation.resume()
                }
            }
        }
    }

    /// Call from the app delegate when iOS relaunches the app for background
    /// URLSession events. Retains the completion handler until delegate events
    /// and their durable metadata updates have finished.
    public func handleEventsForBackgroundURLSession(
        identifier: String,
        completionHandler: @escaping () -> Void
    ) {
        guard identifier == self.identifier else {
            completionHandler()
            return
        }
        lock.lock()
        backgroundEventsCompletion = completionHandler
        lock.unlock()
    }

    /// Reconciles persisted in-flight tasks with tasks still owned by the
    /// background transfer daemon after an app relaunch.
    public func reconcileAfterRelaunch() async {
        let activeTasks = await allDownloadTasks()
        let activeIDs = Set(activeTasks.compactMap {
            Self.parseTaskDescription($0.taskDescription)?.id
        })
        let savedTasks = await store.allTasks()

        for saved in savedTasks where saved.status == .paused && activeIDs.contains(saved.id) {
            _ = try? await store.update(id: saved.id) { value in
                if value.status == .paused { try value.start() }
            }
        }
    }

    private func allDownloadTasks() async -> [URLSessionDownloadTask] {
        await withCheckedContinuation { continuation in
            session.getTasksWithCompletionHandler { _, _, downloads in
                continuation.resume(returning: downloads)
            }
        }
    }

    public func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                           didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
                           totalBytesExpectedToWrite: Int64) {
        guard let id = Self.parseTaskDescription(downloadTask.taskDescription)?.id else { return }
        if lock.withLock({ deletingTaskIDs.contains(id) }) { return }
        let expected = totalBytesExpectedToWrite > 0 ? totalBytesExpectedToWrite : nil
        updates.enqueue { [store] in
            _ = try? await store.update(id: id) { task in
                guard task.status == .downloading else { return }
                try task.recordProgress(bytesWritten: max(task.bytesWritten, totalBytesWritten),
                                        expectedBytes: expected)
            }
        }
    }

    public func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                           didFinishDownloadingTo location: URL) {
        // iOS requires the temporary download file to be moved before this
        // delegate callback returns. The destination is embedded in taskDescription
        // so this operation does not need an asynchronous store lookup.
        guard let metadata = Self.parseTaskDescription(downloadTask.taskDescription) else { return }
        guard let response = downloadTask.response as? HTTPURLResponse else {
            lock.withLock {
                fileMoveResults[metadata.id] = false
                fileResponseResults[metadata.id] = (statusCode: 0, expectedBytes: nil)
            }
            try? FileManager.default.removeItem(at: location)
            return
        }

        let statusCode = response.statusCode
        let responseExpectedBytes: Int64?
        if statusCode == 206,
           let contentRange = response.value(forHTTPHeaderField: "Content-Range"),
           let total = Self.contentRangeTotal(contentRange) {
            responseExpectedBytes = total
        } else {
            responseExpectedBytes = response.expectedContentLength > 0 ? response.expectedContentLength : nil
        }

        lock.lock()
        guard !deletingTaskIDs.contains(metadata.id) else {
            lock.unlock()
            try? FileManager.default.removeItem(at: location)
            return
        }
        fileResponseResults[metadata.id] = (statusCode: statusCode, expectedBytes: responseExpectedBytes)

        // URLSessionDownloadTask can finish without a transport error even when
        // the server returned an HTTP error page (for example, a 9-byte 404).
        // Never move an error response into the user's Downloads folder.
        guard statusCode == 200 || statusCode == 206 else {
            fileMoveResults[metadata.id] = false
            lock.unlock()
            try? FileManager.default.removeItem(at: location)
            return
        }

        let destination = URL(fileURLWithPath: metadata.destinationPath)
        let moved: Bool
        do {
            try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            if FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.removeItem(at: destination)
            }
            try FileManager.default.moveItem(at: location, to: destination)
            moved = true
        } catch {
            moved = false
        }
        fileMoveResults[metadata.id] = moved
        lock.unlock()
    }

    public func urlSession(_ session: URLSession, task: URLSessionTask,
                           didCompleteWithError error: Error?) {
        guard let metadata = Self.parseTaskDescription(task.taskDescription) else { return }
        let id = metadata.id
        lock.lock()
        let wasPausing = pausingTaskIDs.contains(id)
        let wasDeleting = deletingTaskIDs.remove(id) != nil
        let fileMoved = fileMoveResults.removeValue(forKey: id) ?? false
        let responseResult = fileResponseResults.removeValue(forKey: id)
        lock.unlock()

        if wasDeleting || wasPausing { return }
        updates.enqueue { [store] in
            _ = try? await store.update(id: id) { value in
                guard value.status == .downloading else { return }
                if let error {
                    let resumeData = (error as NSError).userInfo[NSURLSessionDownloadTaskResumeData] as? Data
                    try value.pause(resumeData: resumeData)
                } else if let responseResult,
                          responseResult.statusCode != 200 && responseResult.statusCode != 206 {
                    try value.markFailed(message: responseResult.statusCode == 0
                        ? "The server returned an invalid HTTP response."
                        : "The server returned HTTP \(responseResult.statusCode), not a downloadable file.")
                    try? FileManager.default.removeItem(atPath: metadata.destinationPath)
                } else if fileMoved {
                    let attributes = try FileManager.default.attributesOfItem(atPath: metadata.destinationPath)
                    guard let size = (attributes[.size] as? NSNumber)?.int64Value, size >= 0 else {
                        try value.markFailed(message: "Downloaded file size could not be verified.")
                        try? FileManager.default.removeItem(atPath: metadata.destinationPath)
                        return
                    }
                    let expected = value.expectedBytes.flatMap { $0 > 0 ? $0 : nil }
                        ?? responseResult?.expectedBytes
                    if let message = HTTPDownloadResponseValidator.failureMessage(
                        statusCode: responseResult?.statusCode ?? 200,
                        expectedBytes: expected,
                        actualBytes: size,
                        fileURL: URL(fileURLWithPath: metadata.destinationPath)
                    ) {
                        try value.markFailed(message: message)
                        try? FileManager.default.removeItem(atPath: metadata.destinationPath)
                        return
                    }
                    try value.complete(actualBytes: size)
                } else {
                    try value.markFailed(message: "iOS background download completed but its temporary file could not be moved.")
                }
            }
        }
    }

    public func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        updates.enqueue { [weak self] in
            guard let self else { return }
            let completion = self.lock.withLock {
                let handler = self.backgroundEventsCompletion
                self.backgroundEventsCompletion = nil
                return handler
            }
            if let completion {
                DispatchQueue.main.async(execute: DispatchWorkItem(block: completion))
            }
        }
    }

    private static func contentRangeTotal(_ value: String) -> Int64? {
        let pieces = value.split(separator: "/", maxSplits: 1)
        guard pieces.count == 2, pieces[1] != "*" else { return nil }
        return Int64(pieces[1])
    }

    private static func makeTaskDescription(id: UUID, destinationPath: String) -> String {
        let encodedPath = Data(destinationPath.utf8).base64EncodedString()
        return "\(id.uuidString)|\(encodedPath)"
    }

    private static func parseTaskDescription(_ value: String?) -> (id: UUID, destinationPath: String)? {
        guard let value else { return nil }
        let parts = value.split(separator: "|", maxSplits: 1)
        guard parts.count == 2,
              let id = UUID(uuidString: String(parts[0])),
              let pathData = Data(base64Encoded: String(parts[1])),
              let path = String(data: pathData, encoding: .utf8),
              !path.isEmpty else { return nil }
        return (id, path)
    }
}

private final class BackgroundStoreUpdateQueue: @unchecked Sendable {
    private let lock = NSLock()
    private var tail: Task<Void, Never>?

    func enqueue(_ operation: @escaping @Sendable () async -> Void) {
        lock.lock()
        let previous = tail
        tail = Task {
            await previous?.value
            await operation()
        }
        lock.unlock()
    }
}
#endif
