#if os(iOS) && canImport(ActivityKit)
import ActivityKit
import Foundation

@available(iOS 16.1, *)
public struct DownloadActivityAttributes: ActivityAttributes {
    public struct ContentState: Codable, Hashable {
        public var progress: Double
        public var bytesWritten: Int64
        public var expectedBytes: Int64?
        public var status: String
        public var updatedAt: Date

        public init(progress: Double, bytesWritten: Int64, expectedBytes: Int64?,
                    status: String, updatedAt: Date = Date()) {
            self.progress = min(1, max(0, progress))
            self.bytesWritten = max(0, bytesWritten)
            self.expectedBytes = expectedBytes
            self.status = status
            self.updatedAt = updatedAt
        }
    }

    public var downloadID: UUID
    public var fileName: String

    public init(downloadID: UUID, fileName: String) {
        self.downloadID = downloadID
        self.fileName = fileName
    }
}
#endif
