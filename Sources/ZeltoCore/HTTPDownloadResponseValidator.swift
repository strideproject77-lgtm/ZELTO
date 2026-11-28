import Foundation

/// Validates the final HTTP response, on-disk byte count, and common archive
/// signatures before a background download is marked completed.
public enum HTTPDownloadResponseValidator {
    public static func failureMessage(statusCode: Int, expectedBytes: Int64?,
                                      actualBytes: Int64, fileURL: URL? = nil) -> String? {
        guard statusCode == 200 || statusCode == 206 else {
            return statusCode == 0
                ? "The server returned an invalid HTTP response."
                : "The server returned HTTP \(statusCode), not a downloadable file."
        }
        guard actualBytes >= 0 else {
            return "The downloaded file has an invalid size."
        }
        if let expectedBytes, expectedBytes > 0, actualBytes != expectedBytes {
            return "Download incomplete: received \(actualBytes) of \(expectedBytes) bytes. The partial file was discarded."
        }
        if let fileURL, fileURL.pathExtension.lowercased() == "zip",
           !isValidZIPArchive(at: fileURL) {
            return "The server response is not a valid ZIP archive. The downloaded file was discarded."
        }
        return nil
    }

    /// Checks the ZIP local-file/empty-archive signature and end-of-central-
    /// directory record. This catches short text error bodies saved as .zip.
    public static func isValidZIPArchive(at fileURL: URL) -> Bool {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: fileURL.path),
              let size = (attributes[.size] as? NSNumber)?.int64Value,
              size >= 22,
              let handle = try? FileHandle(forReadingFrom: fileURL) else {
            return false
        }
        defer { try? handle.close() }

        guard let prefix = try? handle.read(upToCount: 4_096),
              let prefix,
              prefix.range(of: Data([0x50, 0x4B, 0x03, 0x04])) != nil
                || prefix.starts(with: Data([0x50, 0x4B, 0x05, 0x06])) else {
            return false
        }

        let tailLength = UInt64(min(size, 65_557))
        guard (try? handle.seek(toOffset: UInt64(size) - tailLength)) != nil,
              let tail = try? handle.readToEnd(),
              let tail,
              tail.range(of: Data([0x50, 0x4B, 0x05, 0x06])) != nil else {
            return false
        }
        return true
    }
}
