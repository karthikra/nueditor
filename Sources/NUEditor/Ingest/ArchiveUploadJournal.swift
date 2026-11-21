import Foundation

/// Per-machine resume state for multipart archive uploads, one file per footage id.
///
/// The tower keeps no multipart state, so this is the only record of which parts already reached
/// S3. It belongs to this Mac's upload, not to the project: another machine cannot resume it.
actor ArchiveUploadJournal {
    static let shared = ArchiveUploadJournal(
        directory: FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("NUEditor/ArchiveUploads", isDirectory: true)
    )

    struct Entry: Codable, Sendable, Equatable {
        let footageId: String
        /// The original's whole-file SHA-256; a journal for different bytes is never resumed.
        let checksum: String
        let plan: NUEDITBackendClient.MultipartPlan
        let startedAt: Date
        var completed: [Int: NUEDITBackendClient.CompletedPart]

        var remainingPartNumbers: [Int] {
            guard plan.partCount > 0 else { return [] }
            return (1...plan.partCount).filter { completed[$0] == nil }
        }
    }

    private let directory: URL

    init(directory: URL) {
        self.directory = directory
    }

    func entry(footageId: String) throws -> Entry? {
        let url = fileURL(footageId)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        do {
            return try JSONDecoder().decode(Entry.self, from: Data(contentsOf: url))
        } catch {
            // An unreadable journal can't be resumed; drop it so the next pass starts clean.
            try? FileManager.default.removeItem(at: url)
            return nil
        }
    }

    func save(_ entry: Entry) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try JSONEncoder().encode(entry).write(to: fileURL(entry.footageId), options: .atomic)
    }

    func remove(footageId: String) throws {
        let url = fileURL(footageId)
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        try FileManager.default.removeItem(at: url)
    }

    private func fileURL(_ footageId: String) -> URL {
        let safe = footageId.filter { $0.isLetter || $0.isNumber || $0 == "-" }
        return directory.appendingPathComponent("\(safe).json")
    }
}
