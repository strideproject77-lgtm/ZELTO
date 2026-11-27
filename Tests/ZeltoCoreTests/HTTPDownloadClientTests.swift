import Foundation
import XCTest
@testable import ZeltoCore

final class HTTPDownloadClientTests: XCTestCase {
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
