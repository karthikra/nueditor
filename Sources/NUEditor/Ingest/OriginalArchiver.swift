import Foundation

/// Copies a camera original to the tower's S3 archive so the external drive stops being the only
/// full-resolution copy. The bytes go from this Mac straight to S3; the tower only signs and verifies.
///
/// Sequence: check the original locally → presign → PUT → complete. `complete` runs after every
/// PUT attempt, because a presign leaves the tower's row `uploading` and only `complete` moves it on.
enum OriginalArchiver {
    /// S3's ceiling for a single PUT. Larger originals wait for the tower's multipart flow.
    static let singleUploadLimitBytes = 5 << 30

    /// Assumed worst-case uplink when sizing the grant, so a slow upload doesn't outlive its URL.
    static let minimumBytesPerSecond = 1 << 20
    static let grantLifetime: ClosedRange<Int> = 3_600...86_400

    enum Outcome: Sendable, Equatable {
        case archived(uri: String)
        /// The tower already holds it; the URI isn't returned on this path.
        case alreadyArchived
        /// Nothing went wrong, but nothing was archived: tower away, opted out, drive unmounted,
        /// or too large for a single upload. Safe to retry later.
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
        singleUploadLimit: Int = singleUploadLimitBytes
    ) async -> Outcome {
        guard await client.currentSettings().isConfigured else { return .skipped("No tower configured.") }

        switch await checkOriginal(request) {
        case .ready: break
        case .unavailable(let reason): return .skipped(reason)
        case .changed(let reason): return .failed(reason)
        }
        // Presigning marks the row `uploading`; only ask for a grant we can actually use.
        guard request.identity.fileSizeBytes <= singleUploadLimit else {
            return .skipped("Larger than 5 GB; the tower can't take it in one upload yet.")
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
            case .api: return .failed(error.localizedDescription)
            }
        }
        if (error as? URLError)?.code == .cancelled { return .skipped("Cancelled.") }
        return .failed(error.localizedDescription)
    }
}
