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
