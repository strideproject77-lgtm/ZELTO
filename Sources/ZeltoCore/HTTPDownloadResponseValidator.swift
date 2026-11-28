import Foundation

/// Validates the final HTTP response and on-disk byte count before a
/// background download is marked completed.
public enum HTTPDownloadResponseValidator {
    public static func failureMessage(statusCode: Int, expectedBytes: Int64?,
                                      actualBytes: Int64) -> String? {
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
        return nil
    }
}
