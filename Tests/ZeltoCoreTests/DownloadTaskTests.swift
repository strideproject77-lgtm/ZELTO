import Foundation
import XCTest
@testable import ZeltoCore

final class DownloadTaskTests: XCTestCase {
    func testProgressAndPauseResumeState() throws {
        var task = try DownloadTask(sourceURL: URL(string: "https://example.com/file.zip")!, destinationPath: "/tmp/file.zip")
        XCTAssertNil(task.progress)
        try task.start()
        try task.recordProgress(bytesWritten: 50, expectedBytes: 100, etag: "v1")
        XCTAssertEqual(task.progress, 0.5)
        try task.pause(resumeData: Data([1, 2, 3]))
        XCTAssertEqual(task.status, .paused)
        try task.start()
        XCTAssertEqual(task.resumeData, Data([1, 2, 3]))
        try task.recordProgress(bytesWritten: 100, expectedBytes: 100)
        try task.complete()
        XCTAssertEqual(task.status, .completed)
        XCTAssertNil(task.resumeData)
    }

    func testProgressCannotMoveBackwards() throws {
        var task = try DownloadTask(sourceURL: URL(string: "https://example.com/a")!, destinationPath: "/tmp/a")
        try task.start()
        try task.recordProgress(bytesWritten: 10, expectedBytes: 20)
        XCTAssertThrowsError(try task.recordProgress(bytesWritten: 9, expectedBytes: 20))
    }

    func testStorePersistsAndRestoresResumeMetadata() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let file = directory.appendingPathComponent("downloads.json")
        defer { try? FileManager.default.removeItem(at: directory) }
        let task = try DownloadTask(sourceURL: URL(string: "https://example.com/a")!, destinationPath: directory.appendingPathComponent("partial.bin").path)
        let store = try DownloadStore(fileURL: file)
        try await store.insert(task)
        _ = try await store.update(id: task.id) { value in
            try value.start()
            try value.recordProgress(bytesWritten: 123, expectedBytes: 456, etag: "abc")
            try value.pause(resumeData: Data([9, 8, 7]))
        }
        let restored = try DownloadStore(fileURL: file)
        let saved = await restored.task(id: task.id)
        XCTAssertEqual(saved?.status, .paused)
        XCTAssertEqual(saved?.bytesWritten, 123)
        XCTAssertEqual(saved?.etag, "abc")
        XCTAssertEqual(saved?.resumeData, Data([9, 8, 7]))
    }

    func testStoreAutomaticallyRecoversInterruptedTaskUsingFileSize() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let metadata = directory.appendingPathComponent("downloads.json")
        let partial = directory.appendingPathComponent("archive.part")
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data(repeating: 0x5A, count: 37).write(to: partial)
        let task = try DownloadTask(sourceURL: URL(string: "https://example.com/archive")!,
                                    destinationPath: partial.path, status: .downloading,
                                    bytesWritten: 20, expectedBytes: 100, etag: "\"stable\"",
                                    resumeData: Data([1, 2, 3]))
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode([task]).write(to: metadata)

        let recoveredStore = try DownloadStore(fileURL: metadata)
        let recovered = await recoveredStore.task(id: task.id)
        XCTAssertEqual(recovered?.status, .paused)
        XCTAssertEqual(recovered?.bytesWritten, 37)
        XCTAssertEqual(recovered?.expectedBytes, 100)
        XCTAssertEqual(recovered?.etag, "\"stable\"")
        XCTAssertNil(recovered?.resumeData)
    }

    func testStoreDropsInvalidOversizedPartialFileOnRecovery() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let metadata = directory.appendingPathComponent("downloads.json")
        let partial = directory.appendingPathComponent("archive.part")
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data(repeating: 0x5A, count: 120).write(to: partial)
        let task = try DownloadTask(sourceURL: URL(string: "https://example.com/archive")!,
                                    destinationPath: partial.path, status: .downloading,
                                    bytesWritten: 120, expectedBytes: 100, etag: "\"stable\"")
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode([task]).write(to: metadata)

        let recoveredStore = try DownloadStore(fileURL: metadata)
        let recovered = await recoveredStore.task(id: task.id)
        XCTAssertEqual(recovered?.status, .paused)
        XCTAssertEqual(recovered?.bytesWritten, 0)
        XCTAssertNil(recovered?.etag)
        XCTAssertFalse(FileManager.default.fileExists(atPath: partial.path))
    }
}
