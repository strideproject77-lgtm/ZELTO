import Foundation

public enum DownloadStatus: String, Codable, Sendable {
    case queued, downloading, paused, failed, completed
}

/// Durable download metadata. Resume data is opaque URLSession data and may be unavailable.
public struct DownloadTask: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public let sourceURL: URL
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
        guard status == .downloading else {
            throw DownloadTaskError.invalidTransition(from: status, operation: "complete")
        }
        status = .completed; resumeData = nil; failureMessage = nil
        if let expectedBytes, expectedBytes > 0 { bytesWritten = expectedBytes }
        updatedAt = Date()
    }
}
