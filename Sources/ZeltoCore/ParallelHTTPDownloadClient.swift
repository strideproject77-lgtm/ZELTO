import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// An inclusive HTTP byte range.
public struct HTTPByteRange: Codable, Equatable, Sendable {
    public let index: Int
    public let lowerBound: Int64
    public let upperBound: Int64

    public init(index: Int, lowerBound: Int64, upperBound: Int64) {
        self.index = index
        self.lowerBound = lowerBound
        self.upperBound = upperBound
    }

    public var byteCount: Int64 { upperBound - lowerBound + 1 }
    public var headerValue: String { "bytes=\(lowerBound)-\(upperBound)" }
}

/// Deterministic range partitioning, independently testable without networking.
public enum HTTPRangePlanner {
    public static func makePlan(totalBytes: Int64, preferredConnections: Int = 4,
                                minimumSegmentBytes: Int64 = 4 * 1024 * 1024) -> [HTTPByteRange]? {
        guard totalBytes >= minimumSegmentBytes * 2,
              preferredConnections >= 2, minimumSegmentBytes > 0 else { return nil }
        let possible = Int(totalBytes / minimumSegmentBytes)
        let count = min(max(2, preferredConnections), possible)
        let base = totalBytes / Int64(count)
        let remainder = totalBytes % Int64(count)
        var cursor: Int64 = 0
        return (0..<count).map { index in
            let length = base + (Int64(index) < remainder ? 1 : 0)
            let range = HTTPByteRange(index: index, lowerBound: cursor,
                                      upperBound: cursor + length - 1)
            cursor += length
            return range
        }
    }

    /// Parses a Content-Range value such as "bytes 0-1048575/8388608".
    public static func parseContentRange(_ value: String) -> (start: Int64, end: Int64, total: Int64)? {
        let pieces = value.split(separator: " ", maxSplits: 1)
        guard pieces.count == 2, pieces[0].lowercased() == "bytes" else { return nil }
        let totalParts = pieces[1].split(separator: "/", maxSplits: 1)
        guard totalParts.count == 2, let total = Int64(totalParts[1]), total > 0 else { return nil }
        let bounds = totalParts[0].split(separator: "-", maxSplits: 1)
        guard bounds.count == 2, let start = Int64(bounds[0]),
              let end = Int64(bounds[1]), start >= 0, end >= start, end < total else { return nil }
        return (start, end, total)
    }
}

public struct ParallelDownloadProgress: Sendable, Equatable {
    public let bytesWritten: Int64
    public let expectedBytes: Int64
    public let completedSegments: Int
    public let totalSegments: Int
    public let etag: String?
    public let lastModified: String?
}

private struct ParallelDownloadManifest: Codable {
    let version: Int
    let sourceURL: String
    let totalBytes: Int64
    let etag: String?
    let lastModified: String?
    let ranges: [HTTPByteRange]
    var completedSegmentIndexes: Set<Int>
}

/// Multi-connection HTTP downloader for servers that support byte ranges.
///
/// Completed segment files and their manifest are durable. If the app is
/// interrupted, completed ranges are reused and only missing ranges are fetched.
/// An interrupted in-flight range is retried from its beginning; it is never
/// mistaken for completed data.
public final class ParallelHTTPDownloadClient: @unchecked Sendable {
    public static let defaultMinimumFileSize: Int64 = 8 * 1024 * 1024

    private let session: URLSession
    private let preferredConnections: Int
    private let minimumFileSize: Int64
    private let fileManager = FileManager.default

    public init(session: URLSession = .shared, preferredConnections: Int = 4,
                minimumFileSize: Int64 = ParallelHTTPDownloadClient.defaultMinimumFileSize) {
        self.session = session
        self.preferredConnections = min(8, max(2, preferredConnections))
        self.minimumFileSize = max(1, minimumFileSize)
    }

    /// Returns nil when the resource is too small or the origin does not safely
    /// support validated byte ranges. Callers should then use their single-stream path.
    public func downloadIfSupported(
        task: DownloadTask,
        progress: (@Sendable (ParallelDownloadProgress) -> Void)? = nil
    ) async throws -> HTTPDownloadResult? {
        let identity: ParallelResourceIdentity
        do {
            identity = try await probe(task.sourceURL)
        } catch ParallelHTTPDownloadError.rangeUnsupported {
            return nil
        } catch ParallelHTTPDownloadError.missingValidator {
            return nil
        }
        guard identity.totalBytes >= minimumFileSize,
              let validator = identity.validator,
              let ranges = HTTPRangePlanner.makePlan(totalBytes: identity.totalBytes,
                                                     preferredConnections: preferredConnections) else {
            return nil
        }

        if let known = task.expectedBytes, known > 0, known != identity.totalBytes {
            return nil
        }

        let destination = URL(fileURLWithPath: task.destinationPath)
        let segmentDirectory = destination.deletingLastPathComponent()
            .appendingPathComponent(".zelto-\(task.id.uuidString.lowercased()).segments", isDirectory: true)
        try fileManager.createDirectory(at: segmentDirectory, withIntermediateDirectories: true)

        let manifestURL = segmentDirectory.appendingPathComponent("manifest.json")
        var manifest = loadManifest(at: manifestURL, sourceURL: task.sourceURL,
                                    identity: identity, ranges: ranges)
        if manifest == nil {
            try? fileManager.removeItem(at: segmentDirectory)
            try fileManager.createDirectory(at: segmentDirectory, withIntermediateDirectories: true)
            manifest = ParallelDownloadManifest(version: 1, sourceURL: task.sourceURL.absoluteString,
                                                 totalBytes: identity.totalBytes, etag: identity.etag,
                                                 lastModified: identity.lastModified, ranges: ranges,
                                                 completedSegmentIndexes: [])
            try persist(manifest!, to: manifestURL)
        }
        guard var current = manifest else { return nil }

        // Revalidate persisted segment files before trusting the manifest.
        for range in ranges where current.completedSegmentIndexes.contains(range.index) {
            let part = segmentURL(range.index, in: segmentDirectory)
            let size = fileSize(part)
            if size != range.byteCount {
                current.completedSegmentIndexes.remove(range.index)
                try? fileManager.removeItem(at: part)
            }
        }
        try persist(current, to: manifestURL)

        let alreadyCompleted = ranges.filter { current.completedSegmentIndexes.contains($0.index) }
            .reduce(Int64(0)) { $0 + $1.byteCount }
        progress?(ParallelDownloadProgress(bytesWritten: alreadyCompleted,
                                           expectedBytes: identity.totalBytes,
                                           completedSegments: current.completedSegmentIndexes.count,
                                           totalSegments: ranges.count, etag: identity.etag,
                                           lastModified: identity.lastModified))

        let pending = ranges.filter { !current.completedSegmentIndexes.contains($0.index) }
        let state = ParallelManifestState(manifest: current, manifestURL: manifestURL,
                                          directory: segmentDirectory, session: session,
                                          validator: validator, progress: progress)
        try await withThrowingTaskGroup(of: Int.self) { group in
            for range in pending {
                group.addTask {
                    try await state.fetch(range: range, sourceURL: task.sourceURL)
                }
            }
            for try await _ in group {
                // Each worker persists its completion before returning.
            }
        }

        let finalManifest = state.snapshot()
        guard finalManifest.completedSegmentIndexes.count == ranges.count else {
            throw ParallelHTTPDownloadError.incompleteSegments
        }

        let staging = destination.appendingPathExtension("zelto-merging")
        try? fileManager.removeItem(at: staging)
        _ = fileManager.createFile(atPath: staging.path, contents: nil)
        let output = try FileHandle(forWritingTo: staging)
        do {
            for range in ranges.sorted(by: { $0.index < $1.index }) {
                let part = segmentURL(range.index, in: segmentDirectory)
                guard fileSize(part) == range.byteCount else {
                    throw ParallelHTTPDownloadError.segmentSizeMismatch(range.index)
                }
                let input = try FileHandle(forReadingFrom: part)
                defer { try? input.close() }
                while let chunk = try input.read(upToCount: 1024 * 1024), !chunk.isEmpty {
                    try output.write(contentsOf: chunk)
                }
            }
            try output.synchronize()
            try output.close()
            guard fileSize(staging) == identity.totalBytes else {
                throw ParallelHTTPDownloadError.finalSizeMismatch
            }
            try? fileManager.removeItem(at: destination)
            try fileManager.moveItem(at: staging, to: destination)
        } catch {
            try? output.close()
            try? fileManager.removeItem(at: staging)
            throw error
        }

        let result = HTTPDownloadResult(destinationURL: destination, bytesWritten: identity.totalBytes,
                                        expectedBytes: identity.totalBytes, etag: identity.etag,
                                        lastModified: identity.lastModified)
        try? fileManager.removeItem(at: segmentDirectory)
        return result
    }

    private func probe(_ url: URL) async throws -> ParallelResourceIdentity {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 30
        request.setValue("bytes=0-0", forHTTPHeaderField: "Range")
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 206,
              data.count == 1,
              let rawRange = http.value(forHTTPHeaderField: "Content-Range"),
              let parsed = HTTPRangePlanner.parseContentRange(rawRange),
              parsed.start == 0, parsed.end == 0 else {
            throw ParallelHTTPDownloadError.rangeUnsupported
        }
        let identity = ParallelResourceIdentity(totalBytes: parsed.total,
                                                etag: http.value(forHTTPHeaderField: "ETag"),
                                                lastModified: http.value(forHTTPHeaderField: "Last-Modified"))
        guard identity.validator != nil else { throw ParallelHTTPDownloadError.missingValidator }
        return identity
    }

    private func loadManifest(at url: URL, sourceURL: URL, identity: ParallelResourceIdentity,
                              ranges: [HTTPByteRange]) -> ParallelDownloadManifest? {
        guard let data = try? Data(contentsOf: url),
              let manifest = try? JSONDecoder().decode(ParallelDownloadManifest.self, from: data),
              manifest.version == 1, manifest.sourceURL == sourceURL.absoluteString,
              manifest.totalBytes == identity.totalBytes,
              manifest.etag == identity.etag, manifest.lastModified == identity.lastModified,
              manifest.ranges == ranges else { return nil }
        return manifest
    }

    private func persist(_ manifest: ParallelDownloadManifest, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(manifest).write(to: url, options: .atomic)
    }

    private func segmentURL(_ index: Int, in directory: URL) -> URL {
        directory.appendingPathComponent("segment-\(index).part")
    }

    private func fileSize(_ url: URL) -> Int64 {
        ((try? fileManager.attributesOfItem(atPath: url.path))?[.size] as? NSNumber)?.int64Value ?? -1
    }
}

private struct ParallelResourceIdentity {
    let totalBytes: Int64
    let etag: String?
    let lastModified: String?
    var validator: String? {
        if let etag, !etag.hasPrefix("W/") { return etag }
        return lastModified
    }
}

private enum ParallelHTTPDownloadError: Error {
    case rangeUnsupported
    case missingValidator
    case invalidSegmentResponse(Int)
    case invalidContentRange(Int)
    case validatorMismatch(Int)
    case segmentSizeMismatch(Int)
    case finalSizeMismatch
    case incompleteSegments
}

private final class ParallelManifestState: @unchecked Sendable {
    private let lock = NSLock()
    private var manifest: ParallelDownloadManifest
    private let manifestURL: URL
    private let directory: URL
    private let session: URLSession
    private let validator: String
    private let progress: (@Sendable (ParallelDownloadProgress) -> Void)?

    init(manifest: ParallelDownloadManifest, manifestURL: URL, directory: URL,
         session: URLSession, validator: String,
         progress: (@Sendable (ParallelDownloadProgress) -> Void)?) {
        self.manifest = manifest
        self.manifestURL = manifestURL
        self.directory = directory
        self.session = session
        self.validator = validator
        self.progress = progress
    }

    func snapshot() -> ParallelDownloadManifest { lock.withLock { manifest } }

    func fetch(range: HTTPByteRange, sourceURL: URL) async throws -> Int {
        var lastError: Error = ParallelHTTPDownloadError.invalidSegmentResponse(range.index)
        for attempt in 0..<3 {
            do {
                var request = URLRequest(url: sourceURL)
                request.httpMethod = "GET"
                request.timeoutInterval = 120
                request.setValue(range.headerValue, forHTTPHeaderField: "Range")
                request.setValue(validator, forHTTPHeaderField: "If-Range")
                request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
                let (temporaryURL, response) = try await session.download(for: request)
                guard let http = response as? HTTPURLResponse, http.statusCode == 206 else {
                    throw ParallelHTTPDownloadError.invalidSegmentResponse(range.index)
                }
                guard let rawRange = http.value(forHTTPHeaderField: "Content-Range"),
                      let parsed = HTTPRangePlanner.parseContentRange(rawRange),
                      parsed.start == range.lowerBound, parsed.end == range.upperBound,
                      parsed.total == snapshot().totalBytes else {
                    throw ParallelHTTPDownloadError.invalidContentRange(range.index)
                }
                let responseETag = http.value(forHTTPHeaderField: "ETag")
                let responseModified = http.value(forHTTPHeaderField: "Last-Modified")
                guard responseETag == validator || responseModified == validator else {
                    throw ParallelHTTPDownloadError.validatorMismatch(range.index)
                }
                let part = directory.appendingPathComponent("segment-\(range.index).part")
                let size = ((try? FileManager.default.attributesOfItem(atPath: temporaryURL.path))?[.size] as? NSNumber)?.int64Value ?? -1
                guard size == range.byteCount else {
                    throw ParallelHTTPDownloadError.segmentSizeMismatch(range.index)
                }
                try? FileManager.default.removeItem(at: part)
                try FileManager.default.moveItem(at: temporaryURL, to: part)
                markCompleted(range)
                return range.index
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                lastError = error
                if attempt < 2 {
                    try await Task.sleep(for: .milliseconds(300 * (attempt + 1)))
                }
            }
        }
        throw lastError
    }

    private func markCompleted(_ range: HTTPByteRange) {
        let snapshot = lock.withLock { () -> (ParallelDownloadManifest, Int64) in
            manifest.completedSegmentIndexes.insert(range.index)
            let bytes = manifest.ranges
                .filter { manifest.completedSegmentIndexes.contains($0.index) }
                .reduce(Int64(0)) { $0 + $1.byteCount }
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            if let data = try? encoder.encode(manifest) {
                // Keep manifest writes in the same critical section as mutation:
                // concurrent segment completions must never overwrite a newer snapshot.
                try? data.write(to: manifestURL, options: .atomic)
            }
            return (manifest, bytes)
        }
        progress?(ParallelDownloadProgress(bytesWritten: snapshot.1,
                                           expectedBytes: snapshot.0.totalBytes,
                                           completedSegments: snapshot.0.completedSegmentIndexes.count,
                                           totalSegments: snapshot.0.ranges.count,
                                           etag: snapshot.0.etag,
                                           lastModified: snapshot.0.lastModified))
    }
}
