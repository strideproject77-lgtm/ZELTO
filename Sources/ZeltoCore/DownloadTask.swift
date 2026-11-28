import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public enum DownloadStatus: String, Codable, Sendable {
    case queued, downloading, paused, failed, completed
}

/// Durable download metadata. Resume data is opaque URLSession data and may be unavailable.
public struct DownloadTask: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public var sourceURL: URL
    public let destinationPath: String
    public var status: DownloadStatus
    public var bytesWritten: Int64
    public var expectedBytes: Int64?
    public var etag: String?
    public var lastModified: String?
    public var resumeData: Data?
    public var failureMessage: String?
    public let createdAt: Date
    public var updatedAt: Date

    public init(id: UUID = UUID(), sourceURL: URL, destinationPath: String,
                status: DownloadStatus = .queued, bytesWritten: Int64 = 0,
                expectedBytes: Int64? = nil, etag: String? = nil,
                lastModified: String? = nil, resumeData: Data? = nil,
                failureMessage: String? = nil, createdAt: Date = Date(),
                updatedAt: Date = Date()) throws {
        guard let scheme = sourceURL.scheme?.lowercased(),
              ["http", "https"].contains(scheme), sourceURL.host != nil else {
            throw DownloadTaskError.invalidSourceURL
        }
        guard !destinationPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw DownloadTaskError.invalidDestination
        }
        guard bytesWritten >= 0, expectedBytes.map({ $0 >= 0 }) ?? true else {
            throw DownloadTaskError.invalidByteCount
        }
        self.id = id; self.sourceURL = sourceURL; self.destinationPath = destinationPath
        self.status = status; self.bytesWritten = bytesWritten; self.expectedBytes = expectedBytes
        self.etag = etag; self.lastModified = lastModified; self.resumeData = resumeData
        self.failureMessage = failureMessage; self.createdAt = createdAt; self.updatedAt = updatedAt
    }

    public var progress: Double? {
        guard let expectedBytes, expectedBytes > 0 else { return nil }
        return min(1, Double(bytesWritten) / Double(expectedBytes))
    }
}

public enum DownloadTaskError: Error, Equatable {
    case invalidSourceURL, invalidDestination, invalidByteCount
    case invalidTransition(from: DownloadStatus, operation: String)
    case progressCannotMoveBackwards
    case finalByteCountMismatch(expected: Int64, actual: Int64)
}

public extension DownloadTask {
    mutating func start() throws {
        guard status == .queued || status == .paused else {
            throw DownloadTaskError.invalidTransition(from: status, operation: "start")
        }
        status = .downloading; failureMessage = nil; updatedAt = Date()
    }

    mutating func recordProgress(bytesWritten: Int64, expectedBytes: Int64?,
                                etag: String? = nil, lastModified: String? = nil) throws {
        guard status == .downloading else {
            throw DownloadTaskError.invalidTransition(from: status, operation: "recordProgress")
        }
        guard bytesWritten >= self.bytesWritten, bytesWritten >= 0,
              expectedBytes.map({ $0 >= 0 }) ?? true else {
            throw DownloadTaskError.progressCannotMoveBackwards
        }
        self.bytesWritten = bytesWritten
        if let expectedBytes { self.expectedBytes = expectedBytes }
        if let etag { self.etag = etag }
        if let lastModified { self.lastModified = lastModified }
        updatedAt = Date()
    }

    mutating func pause(resumeData: Data? = nil) throws {
        guard status == .downloading else {
            throw DownloadTaskError.invalidTransition(from: status, operation: "pause")
        }
        status = .paused; self.resumeData = resumeData; updatedAt = Date()
    }

    mutating func markFailed(message: String) throws {
        guard status == .downloading || status == .queued else {
            throw DownloadTaskError.invalidTransition(from: status, operation: "fail")
        }
        status = .failed; failureMessage = message; updatedAt = Date()
    }

    mutating func retry() throws {
        guard status == .failed else {
            throw DownloadTaskError.invalidTransition(from: status, operation: "retry")
        }
        status = .queued; failureMessage = nil; updatedAt = Date()
    }

    mutating func complete() throws {
        try complete(actualBytes: expectedBytes ?? bytesWritten)
    }

    /// Completes only after the final on-disk byte count has been verified.
    /// When the server did not provide a length, the actual size becomes the
    /// task's final expected size so the UI can display 100% accurately.
    mutating func complete(actualBytes: Int64) throws {
        guard status == .downloading else {
            throw DownloadTaskError.invalidTransition(from: status, operation: "complete")
        }
        guard actualBytes >= 0 else { throw DownloadTaskError.invalidByteCount }
        if let expectedBytes, expectedBytes > 0, actualBytes != expectedBytes {
            throw DownloadTaskError.finalByteCountMismatch(expected: expectedBytes, actual: actualBytes)
        }
        bytesWritten = actualBytes
        if expectedBytes == nil || expectedBytes == 0 { expectedBytes = actualBytes }
        status = .completed
        resumeData = nil
        failureMessage = nil
        updatedAt = Date()
    }
}


public struct DownloadLinkIdentity: Sendable, Equatable {
    public let contentLength: Int64
    public let etag: String?
    public let lastModified: String?
    public let fileName: String?

    public init(contentLength: Int64, etag: String?, lastModified: String?, fileName: String?) {
        self.contentLength = contentLength
        self.etag = etag
        self.lastModified = lastModified
        self.fileName = fileName
    }

    public func safelyMatches(_ task: DownloadTask) -> Bool {
        guard contentLength > 0,
              task.expectedBytes == contentLength,
              task.bytesWritten > 0,
              task.bytesWritten <= contentLength else { return false }

        let sameStrongETag: Bool = {
            guard let old = task.etag, let new = etag,
                  !old.hasPrefix("W/"), !new.hasPrefix("W/") else { return false }
            return old == new
        }()
        let sameModificationDate = task.lastModified != nil && task.lastModified == lastModified
        guard sameStrongETag || sameModificationDate else { return false }

        if let fileName, !fileName.isEmpty {
            let oldName = URL(fileURLWithPath: task.destinationPath).lastPathComponent
            let oldURLName = task.sourceURL.lastPathComponent
            let oldCandidates = [oldName, oldURLName].filter { !$0.isEmpty }
            if !oldCandidates.contains(where: { $0.caseInsensitiveCompare(fileName) == .orderedSame }) {
                // Matching validators and exact size are stronger than a URL path;
                // signed CDN URLs commonly use different path names.
                return sameStrongETag
            }
        }
        return true
    }
}

/// Inspects a replacement URL without downloading the file body.
public enum DownloadLinkInspector {
    public static func inspect(_ url: URL, session: URLSession = .shared) async throws -> DownloadLinkIdentity {
        var request = URLRequest(url: url)
        request.httpMethod = "HEAD"
        request.timeoutInterval = 30
        let (_, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse,
              (200...299).contains(http.statusCode) else {
            throw DownloadLinkInspectionError.unavailable
        }
        let length = http.value(forHTTPHeaderField: "Content-Length")
            .flatMap(Int64.init) ?? response.expectedContentLength
        guard length > 0 else { throw DownloadLinkInspectionError.unknownLength }
        return DownloadLinkIdentity(
            contentLength: length,
            etag: http.value(forHTTPHeaderField: "ETag"),
            lastModified: http.value(forHTTPHeaderField: "Last-Modified"),
            fileName: Self.fileName(from: http.value(forHTTPHeaderField: "Content-Disposition"))
                ?? url.lastPathComponent
        )
    }

    private static func fileName(from disposition: String?) -> String? {
        guard let disposition else { return nil }
        if let range = disposition.range(of: "filename*=", options: .caseInsensitive) {
            let raw = disposition[range.upperBound...].split(separator: ";", maxSplits: 1).first
                .map(String.init)?.trimmingCharacters(in: CharacterSet(charactersIn: " \""))
            if let raw, let marker = raw.range(of: "''") {
                return String(raw[marker.upperBound...]).removingPercentEncoding
            }
        }
        guard let range = disposition.range(of: "filename=", options: .caseInsensitive) else { return nil }
        return disposition[range.upperBound...].split(separator: ";", maxSplits: 1).first
            .map(String.init)?.trimmingCharacters(in: CharacterSet(charactersIn: " \""))
    }
}

public enum DownloadLinkInspectionError: Error {
    case unavailable
    case unknownLength
}

public extension DownloadTask {
    mutating func replaceExpiredLink(with url: URL, identity: DownloadLinkIdentity) throws {
        guard status == .paused || status == .failed else {
            throw DownloadTaskError.invalidTransition(from: status, operation: "replaceExpiredLink")
        }
        guard identity.safelyMatches(self) else {
            throw DownloadTaskError.progressCannotMoveBackwards
        }
        sourceURL = url
        expectedBytes = identity.contentLength
        etag = identity.etag
        lastModified = identity.lastModified
        resumeData = nil
        status = .paused
        failureMessage = nil
        updatedAt = Date()
    }
}
