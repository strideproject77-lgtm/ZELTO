import Foundation
import XCTest
@testable import ZeltoCore

final class HTTPDownloadClientTests: XCTestCase {
    func testHTTPErrorResponseIsRejectedEvenWhenBodyIsPresent() {
        let message = HTTPDownloadResponseValidator.failureMessage(
            statusCode: 404, expectedBytes: 9, actualBytes: 9
        )
        XCTAssertEqual(message, "The server returned HTTP 404, not a downloadable file.")
    }

    func testSuccessfulHTTPResponseRejectsTruncatedFile() {
        let message = HTTPDownloadResponseValidator.failureMessage(
            statusCode: 200, expectedBytes: 64_000, actualBytes: 9
        )
        XCTAssertEqual(message, "Download incomplete: received 9 of 64000 bytes. The partial file was discarded.")
    }

    func testSuccessfulHTTPResponseAcceptsExactFileSize() {
        XCTAssertNil(HTTPDownloadResponseValidator.failureMessage(
            statusCode: 200, expectedBytes: 64_000, actualBytes: 64_000
        ))
    }

    func testNineByteErrorBodyCannotBeAcceptedAsZIP() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".zip")
        defer { try? FileManager.default.removeItem(at: url) }
        try Data("Not Found".utf8).write(to: url)

        XCTAssertEqual(
            HTTPDownloadResponseValidator.failureMessage(
                statusCode: 200, expectedBytes: 9, actualBytes: 9, fileURL: url
            ),
            "The server response is not a valid ZIP archive. The downloaded file was discarded."
        )
    }

    func testValidEmptyZIPArchivePassesSignatureValidation() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".zip")
        defer { try? FileManager.default.removeItem(at: url) }
        let emptyZIP = Data([
            0x50, 0x4B, 0x05, 0x06, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
        ])
        try emptyZIP.write(to: url)

        XCTAssertTrue(HTTPDownloadResponseValidator.isValidZIPArchive(at: url))
    }

    func testRangeRequestRequiresValidator() throws {
        let client = HTTPDownloadClient()
        let resumable = try DownloadTask(sourceURL: URL(string: "https://example.com/archive")!,
                                         destinationPath: "/tmp/archive", etag: "\"v2\"")
        let request = client.request(for: resumable, existingBytes: 512)
        XCTAssertEqual(request.value(forHTTPHeaderField: "Range"), "bytes=512-")
        XCTAssertEqual(request.value(forHTTPHeaderField: "If-Range"), "\"v2\"")

        let unsafe = try DownloadTask(sourceURL: URL(string: "https://example.com/archive")!,
                                      destinationPath: "/tmp/archive")
        let fresh = client.request(for: unsafe, existingBytes: 512)
        XCTAssertNil(fresh.value(forHTTPHeaderField: "Range"))
    }
}


final class DownloadLinkIdentityTests: XCTestCase {
    func testSameStrongETagAndSizeAllowsExpiredURLReplacement() throws {
        var task = try DownloadTask(
            sourceURL: URL(string: "https://old.example.com/file.zip?token=expired")!,
            destinationPath: "/tmp/file.zip",
            status: .paused,
            bytesWritten: 4096,
            expectedBytes: 100_000,
            etag: "\"stable-v1\""
        )
        let identity = DownloadLinkIdentity(contentLength: 100_000, etag: "\"stable-v1\"",
                                            lastModified: nil, fileName: "file.zip")
        XCTAssertTrue(identity.safelyMatches(task))
        try task.replaceExpiredLink(with: URL(string: "https://new.example.com/file.zip?token=fresh")!,
                                    identity: identity)
        XCTAssertEqual(task.sourceURL.host, "new.example.com")
        XCTAssertEqual(task.bytesWritten, 4096)
        XCTAssertNil(task.resumeData)
        XCTAssertEqual(task.status, .paused)
    }

    func testDifferentETagNeverReusesOldPartialBytes() throws {
        let task = try DownloadTask(
            sourceURL: URL(string: "https://old.example.com/file.zip")!,
            destinationPath: "/tmp/file.zip",
            status: .paused,
            bytesWritten: 4096,
            expectedBytes: 100_000,
            etag: "\"version-1\""
        )
        let changed = DownloadLinkIdentity(contentLength: 100_000, etag: "\"version-2\"",
                                            lastModified: nil, fileName: "file.zip")
        XCTAssertFalse(changed.safelyMatches(task))
    }

    func testDifferentSizeNeverReusesOldPartialBytes() throws {
        let task = try DownloadTask(
            sourceURL: URL(string: "https://old.example.com/file.zip")!,
            destinationPath: "/tmp/file.zip",
            status: .paused,
            bytesWritten: 4096,
            expectedBytes: 100_000,
            etag: "\"same\""
        )
        let changed = DownloadLinkIdentity(contentLength: 100_001, etag: "\"same\"",
                                            lastModified: nil, fileName: "file.zip")
        XCTAssertFalse(changed.safelyMatches(task))
    }
}
