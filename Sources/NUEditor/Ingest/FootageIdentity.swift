import Foundation

/// What a camera original *is*, independently of what it is called or where it is mounted.
///
/// The checksum is the identity: it dedupes re-imports, it is the tower's key for the footage,
/// and it is what a relink matches on when an external drive comes back at a different mount point.
struct FootageIdentity: Codable, Sendable, Equatable {
    /// Lowercase hex SHA-256 of the whole file.
    var checksum: String
    var fileSizeBytes: Int
    /// Media subtype four-character code, e.g. `avc1`, `hvc1`, `apcn`.
    var codec: String?
    /// Identifies the drive itself, not the mount point it happens to have today.
    var volumeUUID: String?
    var volumeLabel: String?
    /// Path within the volume — the half of the location that survives a remount.
    var volumeRelativePath: String?
    /// Where the volume was last seen. Advisory: helpful in a "mount this drive" message, never a key.
    var mountPoint: String?
    /// Read before hashing; a later mismatch means the bytes may no longer match `checksum`.
    var contentModificationDate: Date?

    /// True when the file on disk still looks like the one that was hashed.
    func matches(fileSizeBytes size: Int, contentModificationDate date: Date?) -> Bool {
        guard size == fileSizeBytes else { return false }
        guard let recorded = contentModificationDate, let date else { return true }
        return abs(recorded.timeIntervalSince(date)) < 0.001
    }
}

/// How far a piece of footage has got through ingest. Mirrors `MediaAsset.GenerationStatus`:
/// serialized to the manifest as a string so an unknown future state degrades to `.none`
/// rather than failing the project open.
enum IngestStatus: Equatable, Sendable {
    case none
    case queued
    case identifying
    case proxying
    case uploading
    /// Registered with the tower; the value is the NUEDIT footage id.
    case registered(String)
    /// Identified locally, but the tower has not accepted it yet — the normal offline state.
    case local
    case failed(String)

    var serialized: String {
        switch self {
        case .none: "none"
        case .queued: "queued"
        case .identifying: "identifying"
        case .proxying: "proxying"
        case .uploading: "uploading"
        case .registered(let id): "registered: \(id)"
        case .local: "local"
        case .failed(let message): "failed: \(message)"
        }
    }

    init(serialized: String?) {
        switch serialized {
        case "queued": self = .queued
        case "identifying": self = .identifying
        case "proxying": self = .proxying
        case "uploading": self = .uploading
        case "local": self = .local
        case let value? where value.hasPrefix("registered: "):
            self = .registered(String(value.dropFirst("registered: ".count)))
        case let value? where value.hasPrefix("failed: "):
            self = .failed(String(value.dropFirst("failed: ".count)))
        default: self = .none
        }
    }

    /// Work is in flight. A restart resumes these rather than trusting a stale in-progress state.
    var isActive: Bool {
        switch self {
        case .queued, .identifying, .proxying, .uploading: true
        case .none, .registered, .local, .failed: false
        }
    }

    var label: String {
        switch self {
        case .none: "Not ingested"
        case .queued: "Queued"
        case .identifying: "Identifying"
        case .proxying: "Building proxies"
        case .uploading: "Uploading"
        case .registered: "On the tower"
        case .local: "Local only"
        case .failed(let message): message
        }
    }
}
