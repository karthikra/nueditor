import Foundation

/// Finds a camera original by its content identity on whatever volumes are mounted now.
///
/// A path is only a hint: the same drive mounts at a different point, a card is copied to a backup,
/// a project moves to another Mac. The checksum is the identity, so a file is accepted only when
/// the evidence matches it — never on a filename alone.
enum OriginalLocator {
    struct MountedVolume: Sendable, Equatable {
        let uuid: String?
        let label: String?
        let url: URL
    }

    /// Every mounted volume, including the boot volume. Reads volume metadata: call it off the main actor.
    @concurrent
    static func mountedVolumes() async -> [MountedVolume] {
        let keys: [URLResourceKey] = [.volumeUUIDStringKey, .volumeNameKey]
        let urls = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: keys, options: []) ?? []
        return urls.map { url in
            let values = try? url.resourceValues(forKeys: Set(keys))
            return MountedVolume(uuid: values?.volumeUUIDString, label: values?.volumeName, url: url)
        }
    }

    /// The original's current location, or nil when no mounted volume holds those bytes.
    ///
    /// On the drive it was identified on, a matching size and modification date at the same path
    /// is enough. Anywhere else, a same-size file at that path is accepted only on a full SHA-256 match.
    @concurrent
    static func locate(
        _ identity: FootageIdentity,
        on volumes: [MountedVolume],
        checksum: @Sendable (URL) async throws -> String = { try await FootageProbe.checksum(of: $0) }
    ) async -> URL? {
        guard let relativePath = identity.volumeRelativePath, !relativePath.isEmpty else { return nil }
        let sameDrive = volumes.filter { $0.uuid != nil && $0.uuid == identity.volumeUUID }
        let otherDrives = volumes.filter { $0.uuid == nil || $0.uuid != identity.volumeUUID }

        for volume in sameDrive {
            let candidate = volume.url.appendingPathComponent(relativePath)
            guard let (size, modified) = try? FootageProbe.fileSizeAndModificationDate(of: candidate) else { continue }
            if identity.matches(fileSizeBytes: size, contentModificationDate: modified) { return candidate }
        }
        for volume in otherDrives {
            guard !Task.isCancelled else { return nil }
            let candidate = volume.url.appendingPathComponent(relativePath)
            guard let (size, _) = try? FootageProbe.fileSizeAndModificationDate(of: candidate),
                  size == identity.fileSizeBytes,
                  let hash = try? await checksum(candidate), hash == identity.checksum else { continue }
            return candidate
        }
        return nil
    }
}
