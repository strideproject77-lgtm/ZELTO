#if os(iOS)
import Foundation
import UIKit

/// Owns a system-managed background URLSession download queue.
///
/// The host app must forward
/// `application(_:handleEventsForBackgroundURLSession:completionHandler:)`
/// to `handleEventsForBackgroundURLSession(identifier:completionHandler:)`.
/// The session identifier must remain stable across app launches.
public final class BackgroundDownloadManager: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    public static let defaultIdentifier = "com.ahmiidev.zelto.background-downloads"

    private let store: DownloadStore
    private let identifier: String
    private let lock = NSLock()
    private var session: URLSession!
    private var backgroundEventsCompletion: (() -> Void)?
    private var movedFiles: Set<UUID> = []
    private var fileMoveFailures: [UUID: String] = [:]
    private var pausingTaskIDs: Set<UUID> = []
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
        downloadTask.taskDescription = id.uuidString
        downloadTask.resume()
        return downloadTask.taskIdentifier
    }

    /// Requests a cooperative pause. iOS may provide opaque resume data; if it
    /// does not, the next enqueue safely restarts using the normal HTTP request.
    public func pause(id: UUID) async throws {
        let tasks = await allDownloadTasks()
        guard let task = tasks.first(where: { $0.taskDescription == id.uuidString }) else {
            _ = try await store.update(id: id) { value in
                if value.status == .downloading { try value.pause() }
            }
            return
        }

        lock.lock()
        pausingTaskIDs.insert(id)
        lock.unlock()

        await withCheckedContinuation { continuation in
            task.cancel { [weak self] resumeData in
                guard let self else { continuation.resume(); return }
                Task {
                    _ = try? await self.store.update(id: id) { value in
                        if value.status == .downloading { try value.pause(resumeData: resumeData) }
                    }
                    self.lock.lock()
                    self.pausingTaskIDs.remove(id)
                    self.lock.unlock()
                    continuation.resume()
                }
            }
        }
    }

    /// Call from the app delegate when iOS relaunches the app for background
    /// URLSession events. Retains the completion handler until all delegate
    /// events have been delivered.
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
        let activeIDs = Set(activeTasks.compactMap { $0.taskDescription }.compactMap(UUID.init(uuidString:)))
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
        guard let id = UUID(uuidString: downloadTask.taskDescription ?? "") else { return }
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
        guard let id = UUID(uuidString: downloadTask.taskDescription ?? ""),
              let saved = updates.cachedDestination(for: id) else {
            // Destination is retrieved from the durable store below when possible.
            guard let id = UUID(uuidString: downloadTask.taskDescription ?? "") else { return }
            Task { [weak self] in await self?.moveDownloadedFile(from: location, id: id) }
            return
        }
        do {
            let destination = URL(fileURLWithPath: saved)
            try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            if FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.removeItem(at: destination)
            }
            try FileManager.default.moveItem(at: location, to: destination)
            lock.lock(); movedFiles.insert(id); lock.unlock()
        } catch {
            lock.lock(); fileMoveFailures[id] = error.localizedDescription; lock.unlock()
        }
    }

    private func moveDownloadedFile(from location: URL, id: UUID) async {
        guard let saved = await store.task(id: id) else { return }
        let destination = URL(fileURLWithPath: saved.destinationPath)
        do {
            try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            if FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.removeItem(at: destination)
            }
            try FileManager.default.moveItem(at: location, to: destination)
            lock.lock(); movedFiles.insert(id); lock.unlock()
        } catch {
            lock.lock(); fileMoveFailures[id] = error.localizedDescription; lock.unlock()
        }
    }

    public func urlSession(_ session: URLSession, task: URLSessionTask,
                           didCompleteWithError error: Error?) {
        guard let id = UUID(uuidString: task.taskDescription ?? "") else { return }
        lock.lock()
        let wasPausing = pausingTaskIDs.contains(id)
        let moveFailure = fileMoveFailures.removeValue(forKey: id)
        let didMove = movedFiles.remove(id) != nil
        lock.unlock()

        if wasPausing { return }
        updates.enqueue { [store] in
            _ = try? await store.update(id: id) { value in
                guard value.status == .downloading else { return }
                if let error {
                    let resumeData = (error as NSError).userInfo[NSURLSessionDownloadTaskResumeData] as? Data
                    try value.pause(resumeData: resumeData)
                } else if let moveFailure {
                    try value.markFailed(message: moveFailure)
                } else if didMove {
                    try value.complete()
                } else {
                    try value.pause()
                }
            }
        }
    }

    public func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        updates.enqueue { [weak self] in
            guard let self else { return }
            self.lock.lock()
            let completion = self.backgroundEventsCompletion
            self.backgroundEventsCompletion = nil
            self.lock.unlock()
            if let completion {
                DispatchQueue.main.async(execute: completion)
            }
        }
    }
}

private final class BackgroundStoreUpdateQueue: @unchecked Sendable {
    private let lock = NSLock()
    private var tail: Task<Void, Never>?
    private var destinations: [UUID: String] = [:]

    func enqueue(_ operation: @escaping @Sendable () async -> Void) {
        lock.lock()
        let previous = tail
        tail = Task {
            await previous?.value
            await operation()
        }
        lock.unlock()
    }

    func cachedDestination(for id: UUID) -> String? {
        lock.lock()
        defer { lock.unlock() }
        return destinations[id]
    }
}
#endif
