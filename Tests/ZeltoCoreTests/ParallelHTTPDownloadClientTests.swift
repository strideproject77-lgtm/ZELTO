import Foundation
import XCTest
@testable import ZeltoCore

final class ParallelHTTPDownloadClientTests: XCTestCase {
    func testRangePlannerCreatesContiguousBalancedRanges() throws {
        let total: Int64 = 20 * 1024 * 1024 + 7
        let ranges = try XCTUnwrap(HTTPRangePlanner.makePlan(
            totalBytes: total, preferredConnections: 4, minimumSegmentBytes: 4 * 1024 * 1024
        ))

        XCTAssertEqual(ranges.count, 4)
        XCTAssertEqual(ranges.first?.lowerBound, 0)
        XCTAssertEqual(ranges.last?.upperBound, total - 1)
        XCTAssertEqual(ranges.reduce(Int64(0)) { $0 + $1.byteCount }, total)

        for pair in zip(ranges, ranges.dropFirst()) {
            XCTAssertEqual(pair.0.upperBound + 1, pair.1.lowerBound)
        }
        XCTAssertLessThanOrEqual((ranges.map(\.byteCount).max() ?? 0)
            - (ranges.map(\.byteCount).min() ?? 0), 1)
    }

    func testPlannerUsesAtMostPreferredConnectionCount() throws {
        let ranges = try XCTUnwrap(HTTPRangePlanner.makePlan(
            totalBytes: 100 * 1024 * 1024, preferredConnections: 6,
            minimumSegmentBytes: 4 * 1024 * 1024
        ))
        XCTAssertEqual(ranges.count, 6)
    }

    func testPlannerRejectsSmallFilesAndInvalidConfiguration() {
        XCTAssertNil(HTTPRangePlanner.makePlan(totalBytes: 7 * 1024 * 1024))
        XCTAssertNil(HTTPRangePlanner.makePlan(totalBytes: 20 * 1024 * 1024,
                                               preferredConnections: 1))
        XCTAssertNil(HTTPRangePlanner.makePlan(totalBytes: 20 * 1024 * 1024,
                                               minimumSegmentBytes: 0))
    }

    func testContentRangeParserAcceptsValidRange() throws {
        let parsed = try XCTUnwrap(HTTPRangePlanner.parseContentRange("bytes 1048576-2097151/8388608"))
        XCTAssertEqual(parsed.start, 1_048_576)
        XCTAssertEqual(parsed.end, 2_097_151)
        XCTAssertEqual(parsed.total, 8_388_608)
    }

    func testContentRangeParserRejectsMalformedOrOutOfBoundsValues() {
        XCTAssertNil(HTTPRangePlanner.parseContentRange("items 0-1/2"))
        XCTAssertNil(HTTPRangePlanner.parseContentRange("bytes 2-1/8"))
        XCTAssertNil(HTTPRangePlanner.parseContentRange("bytes 0-8/8"))
        XCTAssertNil(HTTPRangePlanner.parseContentRange("bytes 0-1/*"))
    }
}
