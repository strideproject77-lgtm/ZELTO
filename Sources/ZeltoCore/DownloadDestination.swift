import Foundation

/// Builds collision-resistant destination URLs for downloads while keeping the
/// server-provided filename readable. The UUID prefix prevents two URLs with
/// the same basename from silently overwriting one another.
public enum DownloadDestination {
    public static func fileURL(
        in directory: URL,
        suggestedName: String,
        taskID: UUID = UUID()
    ) -> URL {
        let safeName = sanitizedFilename(suggestedName)
        return directory.appendingPathComponent("\(taskID.uuidString.lowercased())-\(safeName)",
                                                isDirectory: false)
    }

    public static func sanitizedFilename(_ suggestedName: String) -> String {
        let forbidden = CharacterSet.controlCharacters
            .union(CharacterSet(charactersIn: "<>:\"/\\|?*"))
        let filtered = String(String.UnicodeScalarView(
            suggestedName.unicodeScalars.filter { !forbidden.contains($0) }
        ))
        let trimmed = filtered.trimmingCharacters(in: .whitespacesAndNewlines.union(.init(charactersIn: ".")))
        return trimmed.isEmpty ? "download" : trimmed
    }
}
