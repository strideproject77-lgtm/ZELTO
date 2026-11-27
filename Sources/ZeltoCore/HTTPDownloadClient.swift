import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public struct HTTPDownloadProgress: Sendable, Equatable {
    public let bytesWritten: Int64
    public let expectedBytes: Int64?
    public let etag: String?
    public let lastModified: String?
}

public struct HTTPDownloadResult: Sendable, Equatable {
    public let destinationURL: URL
    public let bytesWritten: Int64
    public let expectedBytes: Int64?
    public let etag: String?
    public let lastModified: String?
    public var isComplete: Bool {
        guard let expectedBytes, expectedBytes > 0 else { return true }
        return bytesWritten >= expectedBytes
    }
}

public enum HTTPDownloadError: Error, Equatable {
    case invalidHTTPResponse
    case unacceptableStatusCode(Int)
    case invalidContentRange
    case destinationUnavailable
}

/// Streams an HTTP response to disk. Existing partial files are resumed with Range
/// only when a validator (ETag or Last-Modified) is available.
public final class HTTPDownloadClient: @unchecked Sendable {
    private let configuration: URLSessionConfiguration

    public init(configuration: URLSessionConfiguration = .default) {
        self.configuration = configuration
    }

    public func download(
        task: DownloadTask,
        progress: (@Sendable (HTTPDownloadProgress) -> Void)? = nil
    ) async throws -> HTTPDownloadResult {
        let destination = URL(fileURLWithPath: task.destinationPath)
        let manager = FileManager.default
        try manager.createDirectory(at: destination.deletingLastPathComponent(),
                                    withIntermediateDirectories: true)

        let existingSize: Int64
        if manager.fileExists(atPath: destination.path),
           let attributes = try? manager.attributesOfItem(atPath: destination.path),
           let size = attributes[.size] as? NSNumber {
            existingSize = size.int64Value
        } else {
            existingSize = 0
        }

        // Never append bytes from a potentially changed remote object.
        let canResume = existingSize > 0 && (task.etag != nil || task.lastModified != nil)
        let offset = canResume ? existingSize : 0
        if !canResume { try? manager.removeItem(at: destination) }

        var request = URLRequest(url: task.sourceURL)
        request.httpMethod = "GET"
        request.timeoutInterval = 60
        if offset > 0 {
            request.setValue("bytes=\(offset)-", forHTTPHeaderField: "Range")
            request.setValue(task.etag ?? task.lastModified, forHTTPHeaderField: "If-Range")
        }

        let transfer = HTTPFileTransfer(configuration: configuration)
        return try await transfer.run(request: request, destination: destination,
                                      requestedOffset: offset, progress: progress)
    }

    /// Exposed for deterministic tests and diagnostics; does not perform network I/O.
    public func request(for task: DownloadTask, existingBytes: Int64) -> URLRequest {
        var request = URLRequest(url: task.sourceURL)
        request.httpMethod = "GET"
        if existingBytes > 0, let validator = task.etag ?? task.lastModified {
            request.setValue("bytes=\(existingBytes)-", forHTTPHeaderField: "Range")
            request.setValue(validator, forHTTPHeaderField: "If-Range")
        }
        return request
    }
}

private final class HTTPFileTransfer: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let configuration: URLSessionConfiguration
    private let lock = NSLock()
    private var continuation: CheckedContinuation<HTTPDownloadResult, Error>?
    private var session: URLSession?
    private var fileHandle: FileHandle?
    private var destination: URL?
    private var requestedOffset: Int64 = 0
    private var bytesWritten: Int64 = 0
    private var expectedBytes: Int64?
    private var etag: String?
    private var lastModified: String?
    private var progress: (@Sendable (HTTPDownloadProgress) -> Void)?
    private var terminalError: Error?
    private var finished = false

    init(configuration: URLSessionConfiguration) { self.configuration = configuration }

    func run(request: URLRequest, destination: URL, requestedOffset: Int64,
             progress: (@Sendable (HTTPDownloadProgress) -> Void)?) async throws -> HTTPDownloadResult {
        try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            self.continuation = continuation
            self.destination = destination
            self.requestedOffset = requestedOffset
            self.bytesWritten = requestedOffset
            self.progress = progress
            let queue = OperationQueue()
            queue.maxConcurrentOperationCount = 1
            let session = URLSession(configuration: configuration, delegate: self, delegateQueue: queue)
            self.session = session
            lock.unlock()
            session.dataTask(with: request).resume()
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask,
                    didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard let http = response as? HTTPURLResponse, let destination else {
            terminalError = HTTPDownloadError.invalidHTTPResponse
            completionHandler(.cancel); return
        }
        let status = http.statusCode
        guard status == 200 || status == 206 else {
            terminalError = HTTPDownloadError.unacceptableStatusCode(status)
            completionHandler(.cancel); return
        }
        if status == 206 {
            guard let range = http.value(forHTTPHeaderField: "Content-Range"),
                  let parsed = Self.parseContentRange(range), parsed.start == requestedOffset else {
                terminalError = HTTPDownloadError.invalidContentRange
                completionHandler(.cancel); return
            }
            expectedBytes = parsed.total
            do {
                if !FileManager.default.fileExists(atPath: destination.path) {
                    _ = FileManager.default.createFile(atPath: destination.path, contents: nil)
                }
                let handle = try FileHandle(forWritingTo: destination)
                try handle.seekToEnd()
                fileHandle = handle
            } catch {
                terminalError = error; completionHandler(.cancel); return
            }
        } else {
            expectedBytes = http.expectedContentLength >= 0 ? http.expectedContentLength : nil
            do {
                _ = FileManager.default.createFile(atPath: destination.path, contents: nil)
                fileHandle = try FileHandle(forWritingTo: destination)
            } catch {
                terminalError = error; completionHandler(.cancel); return
            }
            bytesWritten = 0
        }
        etag = http.value(forHTTPHeaderField: "ETag")
        lastModified = http.value(forHTTPHeaderField: "Last-Modified")
        progress?(HTTPDownloadProgress(bytesWritten: bytesWritten, expectedBytes: expectedBytes,
                                       etag: etag, lastModified: lastModified))
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        do {
            try fileHandle?.write(contentsOf: data)
            bytesWritten += Int64(data.count)
            progress?(HTTPDownloadProgress(bytesWritten: bytesWritten, expectedBytes: expectedBytes,
                                           etag: etag, lastModified: lastModified))
        } catch {
            terminalError = error
            dataTask.cancel()
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        try? fileHandle?.close()
        fileHandle = nil
        let resultError = terminalError ?? error
        if let resultError { finish(.failure(resultError)); return }
        guard let destination else { finish(.failure(HTTPDownloadError.destinationUnavailable)); return }
        let result = HTTPDownloadResult(destinationURL: destination, bytesWritten: bytesWritten,
                                        expectedBytes: expectedBytes, etag: etag,
                                        lastModified: lastModified)
        finish(.success(result))
    }

    private func finish(_ result: Result<HTTPDownloadResult, Error>) {
        lock.lock()
        guard !finished else { lock.unlock(); return }
        finished = true
        let continuation = self.continuation
        self.continuation = nil
        let session = self.session
        self.session = nil
        lock.unlock()
        session?.finishTasksAndInvalidate()
        continuation?.resume(with: result)
    }

    private static func parseContentRange(_ value: String) -> (start: Int64, end: Int64, total: Int64?)? {
        let pieces = value.split(separator: " ", maxSplits: 1)
        guard pieces.count == 2, pieces[0].lowercased() == "bytes" else { return nil }
        let boundsAndTotal = pieces[1].split(separator: "/", maxSplits: 1)
        guard boundsAndTotal.count == 2 else { return nil }
        let bounds = boundsAndTotal[0].split(separator: "-", maxSplits: 1)
        guard bounds.count == 2, let start = Int64(bounds[0]),
              let end = Int64(bounds[1]), end >= start else { return nil }
        let total = Int64(boundsAndTotal[1])
        return (start, end, total)
    }
}
