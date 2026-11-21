import CryptoKit
import Foundation

/// Copies a camera original to the tower's S3 archive so the external drive stops being the only
/// full-resolution copy. The bytes go from this Mac straight to S3; the tower only signs and verifies.
///
/// Sequence: check the original locally → presign → PUT → complete. `complete` runs after every
/// PUT attempt, because a presign leaves the tower's row `uploading` and only `complete` moves it on.
/// Originals over S3's single-PUT ceiling go up in parts and resume from `ArchiveUploadJournal`.
enum OriginalArchiver {
    /// S3's ceiling for a single PUT.
    static let singleUploadLimitBytes = 5 << 30

    /// The bucket aborts incomplete multipart uploads after 7 days; never resume one that close.
    static let journalMaxAge: TimeInterval = 6 * 24 * 60 * 60
    static let partGrantSeconds = 3_600

    /// Assumed worst-case uplink when sizing the grant, so a slow upload doesn't outlive its URL.
    static let minimumBytesPerSecond = 1 << 20
    static let grantLifetime: ClosedRange<Int> = 3_600...86_400

    enum Outcome: Sendable, Equatable {
        case archived(uri: String)
        /// The tower already holds it; the URI isn't returned on this path.
        case alreadyArchived
        /// Nothing went wrong, but nothing was archived: tower away, opted out, drive unmounted,
        /// or interrupted mid-upload. Safe to retry later; a multipart upload resumes.
        case skipped(String)
        case failed(String)
    }

    struct Request: Sendable {
        let footageId: String
        let originalURL: URL
        let identity: FootageIdentity
    }

    static func grantLifetimeSeconds(forBytes bytes: Int) -> Int {
        let needed = bytes / minimumBytesPerSecond
        return min(max(needed, grantLifetime.lowerBound), grantLifetime.upperBound)
    }

    static func archive(
        _ request: Request,
        client: NUEDITBackendClient = .shared,
        journal: ArchiveUploadJournal = .shared,
        singleUploadLimit: Int = singleUploadLimitBytes
    ) async -> Outcome {
        guard await client.currentSettings().isConfigured else { return .skipped("No tower configured.") }

        switch await checkOriginal(request) {
        case .ready: break
        case .unavailable(let reason): return .skipped(reason)
        case .changed(let reason): return .failed(reason)
        }
        guard request.identity.fileSizeBytes <= singleUploadLimit else {
            return await archiveInParts(request, client: client, journal: journal)
        }

        let grant: NUEDITBackendClient.ArchiveGrant
        do {
            grant = try await client.presignArchive(
                footageId: request.footageId,
                expiresIn: grantLifetimeSeconds(forBytes: request.identity.fileSizeBytes)
            )
        } catch {
            return outcome(for: error)
        }

        let key: String, url: URL, headers: [String: String]
        switch grant {
        case .skipped(let reason, let status):
            return status == "archived" ? .alreadyArchived : .skipped("The tower declined: \(reason).")
        case .upload(let grantedKey, let grantedURL, let grantedHeaders):
            (key, url, headers) = (grantedKey, grantedURL, grantedHeaders)
        }

        var uploadError: Error?
        do {
            try await client.uploadOriginal(request.originalURL, to: url, headers: headers)
        } catch {
            uploadError = error
        }

        // Runs even when cancelled: an unreleased grant leaves the tower's row stuck `uploading`.
        let footageId = request.footageId
        let completion = await Task { try await client.completeArchive(footageId: footageId, key: key) }.result

        switch completion {
        case .success(.archived(let uri)):
            return .archived(uri: uri)
        case .success(.notArchived(let reason)):
            if let uploadError { return outcome(for: uploadError) }
            return .failed(reason)
        case .failure(let error):
            return outcome(for: uploadError ?? error)
        }
    }

    // MARK: - Multipart

    private static func archiveInParts(
        _ request: Request, client: NUEDITBackendClient, journal: ArchiveUploadJournal
    ) async -> Outcome {
        let footageId = request.footageId
        let size = request.identity.fileSizeBytes
        var entry: ArchiveUploadJournal.Entry
        do {
            switch try await resumableEntry(for: request, client: client, journal: journal) {
            case .resume(let saved):
                entry = saved
            case .declined(let outcome):
                return outcome
            }
        } catch {
            return outcome(for: error)
        }

        let plan = entry.plan
        guard plan.covers(size) else {
            await abandon(entry, client: client, journal: journal)
            return .failed("The tower's part plan doesn't match the original's size.")
        }

        for number in entry.remainingPartNumbers {
            guard !Task.isCancelled else {
                return .skipped("Cancelled after \(entry.completed.count) of \(plan.partCount) parts; it resumes.")
            }
            let offset = (number - 1) * plan.partSize
            do {
                let (bytes, checksum) = try await readPart(
                    of: request.originalURL, offset: offset, length: min(plan.partSize, size - offset)
                )
                let grant = try await client.presignArchivePart(
                    footageId: footageId, uploadId: plan.uploadId, partNumber: number,
                    checksumSHA256: checksum, expiresIn: partGrantSeconds
                )
                let etag = try await client.uploadPart(bytes, grant: grant)
                entry.completed[number] = .init(partNumber: number, etag: etag, checksumSHA256: checksum)
                try await journal.save(entry)
            } catch BackendError.api(_, "NoSuchUpload", _) {
                await discard(footageId: footageId, journal: journal)
                return .failed("S3 no longer holds the upload; the next pass starts it again.")
            } catch {
                return outcome(for: error)
            }
        }

        do {
            let completion = try await client.completeMultipartArchive(
                footageId: footageId, uploadId: plan.uploadId, parts: Array(entry.completed.values)
            )
            switch completion {
            case .archived(let uri):
                await discard(footageId: footageId, journal: journal)
                return .archived(uri: uri)
            case .notArchived(let reason):
                await abandon(entry, client: client, journal: journal)
                return .failed(reason)
            }
        } catch {
            return outcome(for: error)
        }
    }

    private enum EntryResolution {
        case resume(ArchiveUploadJournal.Entry)
        case declined(Outcome)
    }

    /// Resumes this Mac's upload of the same bytes, or starts a new one.
    private static func resumableEntry(
        for request: Request, client: NUEDITBackendClient, journal: ArchiveUploadJournal
    ) async throws -> EntryResolution {
        if let saved = try await journal.entry(footageId: request.footageId) {
            if saved.checksum == request.identity.checksum,
               Date().timeIntervalSince(saved.startedAt) < journalMaxAge {
                return .resume(saved)
            }
            await abandon(saved, client: client, journal: journal)
        }
        switch try await client.startMultipartArchive(footageId: request.footageId) {
        case .skipped(let reason, let status):
            return .declined(status == "archived" ? .alreadyArchived : .skipped("The tower declined: \(reason)."))
        case .upload(let plan):
            let entry = ArchiveUploadJournal.Entry(
                footageId: request.footageId, checksum: request.identity.checksum,
                plan: plan, startedAt: Date(), completed: [:]
            )
            try await journal.save(entry)
            return .resume(entry)
        }
    }

    /// Best effort: the bucket's lifecycle rule aborts anything this misses.
    private static func abandon(
        _ entry: ArchiveUploadJournal.Entry, client: NUEDITBackendClient, journal: ArchiveUploadJournal
    ) async {
        do {
            try await client.abortMultipartArchive(footageId: entry.footageId, uploadId: entry.plan.uploadId)
        } catch {
            Log.project.warning("archive abort failed footage=\(entry.footageId): \(Log.detail(error))")
        }
        await discard(footageId: entry.footageId, journal: journal)
    }

    private static func discard(footageId: String, journal: ArchiveUploadJournal) async {
        do {
            try await journal.remove(footageId: footageId)
        } catch {
            Log.project.warning("archive journal removal failed footage=\(footageId): \(Log.detail(error))")
        }
    }

    struct PartReadError: LocalizedError {
        var errorDescription: String? { "The original got shorter while it was uploading; re-identify it." }
    }

    /// Reads and hashes one part. Holds a single part in memory; always off the main actor.
    @concurrent
    static func readPart(of url: URL, offset: Int, length: Int) async throws -> (Data, String) {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        try handle.seek(toOffset: UInt64(offset))
        guard let bytes = try handle.read(upToCount: length), bytes.count == length else { throw PartReadError() }
        return (bytes, Data(SHA256.hash(data: bytes)).base64EncodedString())
    }

    enum OriginalCheck: Sendable, Equatable {
        case ready
        case unavailable(String)
        case changed(String)
    }

    /// Reads file metadata — always off the main actor.
    @concurrent
    static func checkOriginal(_ request: Request) async -> OriginalCheck {
        let url = request.originalURL
        guard FileManager.default.fileExists(atPath: url.path) else {
            let drive = request.identity.volumeLabel.map { " Mount \"\($0)\" to archive it." } ?? ""
            return .unavailable("The original is offline.\(drive)")
        }
        guard let (size, modified) = try? FootageProbe.fileSizeAndModificationDate(of: url) else {
            return .unavailable("Could not read \(url.lastPathComponent).")
        }
        guard request.identity.matches(fileSizeBytes: size, contentModificationDate: modified) else {
            return .changed("\(url.lastPathComponent) changed after it was identified; re-identify it before archiving.")
        }
        return .ready
    }

    /// A tower or S3 that can't be reached is a later retry, not damage to the footage.
    private static func outcome(for error: Error) -> Outcome {
        if error is CancellationError { return .skipped("Cancelled.") }
        if let error = error as? BackendError {
            switch error {
            case .transport(let message): return .skipped(message)
            case .notConfigured: return .skipped("No tower configured.")
            case .unauthorized, .api: return .failed(error.localizedDescription)
            }
        }
        if (error as? URLError)?.code == .cancelled { return .skipped("Cancelled.") }
        return .failed(error.localizedDescription)
    }
}
