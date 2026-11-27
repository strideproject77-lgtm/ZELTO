import Foundation

/// Coordinates a transfer with durable task metadata. Progress writes are serialized
/// so the final completion/pause transition cannot overtake earlier progress updates.
public actor DownloadEngine {
    private let store: DownloadStore
    private let client: HTTPDownloadClient

    public init(store: DownloadStore, client: HTTPDownloadClient = HTTPDownloadClient()) {
        self.store = store
        self.client = client
    }

    @discardableResult
    public func download(id: UUID) async throws -> HTTPDownloadResult {
        guard let saved = await store.task(id: id) else { throw DownloadStoreError.taskNotFound }
        if saved.status == .failed {
            _ = try await store.update(id: id) { try $0.retry() }
        }
        let active = try await store.update(id: id) { try $0.start() }
        let progressQueue = DownloadProgressQueue()
        let store = self.store

        do {
            let result = try await client.download(task: active) { progress in
                progressQueue.enqueue {
                    _ = try? await store.update(id: id) { task in
                        guard task.status == .downloading else { return }
                        // A server may ignore Range and send a fresh 200 response.
                        if progress.bytesWritten < task.bytesWritten {
                            task.bytesWritten = 0
                            task.expectedBytes = nil
                            task.etag = nil
                            task.lastModified = nil
                        }
                        try task.recordProgress(bytesWritten: progress.bytesWritten,
                                                expectedBytes: progress.expectedBytes,
                                                etag: progress.etag,
                                                lastModified: progress.lastModified)
                    }
                }
            }
            await progressQueue.drain()
            _ = try await store.update(id: id) { task in
                try task.recordProgress(bytesWritten: result.bytesWritten,
                                        expectedBytes: result.expectedBytes,
                                        etag: result.etag,
                                        lastModified: result.lastModified)
                try task.complete()
            }
            return result
        } catch {
            await progressQueue.drain()
            _ = try? await store.update(id: id) { task in
                if task.status == .downloading { try task.pause() }
            }
            throw error
        }
    }
}

private final class DownloadProgressQueue: @unchecked Sendable {
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

    func drain() async {
        let pending = lock.withLock { tail }
        await pending?.value
    }
}
