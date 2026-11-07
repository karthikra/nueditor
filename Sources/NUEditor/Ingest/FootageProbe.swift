import AVFoundation
import CryptoKit
import Foundation

/// Reads a camera original's content identity. Every entry point touches the filesystem or a
/// decoder, so all of it runs off the main actor and checks cancellation between chunks — hashing
/// a card full of 4K takes minutes, and quitting must not wait for it.
enum FootageProbe {
    /// 4 MB: large enough that a 500 GB card is a few hundred thousand reads, small enough that
    /// peak memory stays flat and cancellation stays responsive.
    static let chunkSize = 4 << 20

    struct VolumeIdentity: Sendable, Equatable {
        var uuid: String?
        var label: String?
        var relativePath: String?
        var mountPoint: String?
    }

    @concurrent
    static func identity(of url: URL) async throws -> FootageIdentity {
        let (size, modified) = try fileSizeAndModificationDate(of: url)
        let checksum = try await checksum(of: url)
        let volume = volumeIdentity(of: url)
        return FootageIdentity(
            checksum: checksum,
            fileSizeBytes: size,
            codec: await codec(of: url),
            volumeUUID: volume.uuid,
            volumeLabel: volume.label,
            volumeRelativePath: volume.relativePath,
            mountPoint: volume.mountPoint,
            contentModificationDate: modified
        )
    }

    static func fileSizeAndModificationDate(of url: URL) throws -> (Int, Date?) {
        let values = try url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        guard let size = values.fileSize else {
            throw BackendError.transport("Could not read the size of \(url.lastPathComponent).")
        }
        return (size, values.contentModificationDate)
    }

    /// Streamed SHA-256 of the whole file, lowercase hex.
    @concurrent
    static func checksum(of url: URL) async throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            try Task.checkCancellation()
            guard let chunk = try handle.read(upToCount: chunkSize), !chunk.isEmpty else { break }
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    static func fileSize(of url: URL) throws -> Int {
        try fileSizeAndModificationDate(of: url).0
    }

    /// The drive, not the mount point: an external volume comes back at a different path, so the
    /// UUID plus the path *within* the volume is what survives an unplug.
    static func volumeIdentity(of url: URL) -> VolumeIdentity {
        let keys: Set<URLResourceKey> = [.volumeURLKey, .volumeUUIDStringKey, .volumeNameKey]
        guard let values = try? url.resourceValues(forKeys: keys) else { return VolumeIdentity() }
        let mount = values.volume?.path
        return VolumeIdentity(
            uuid: values.volumeUUIDString,
            label: values.volumeName,
            relativePath: mount.flatMap { relativePath(of: url.path, inVolumeAt: $0) },
            mountPoint: mount
        )
    }

    static func relativePath(of path: String, inVolumeAt mountPoint: String) -> String? {
        let root = mountPoint.hasSuffix("/") ? mountPoint : mountPoint + "/"
        guard path.hasPrefix(root) else { return nil }
        let relative = String(path.dropFirst(root.count))
        return relative.isEmpty ? nil : relative
    }

    /// Media subtype four-character code of the first video track, else the first audio track.
    @concurrent
    static func codec(of url: URL) async -> String? {
        let asset = AVURLAsset(url: url)
        for mediaType in [AVMediaType.video, .audio] {
            guard let track = try? await asset.loadTracks(withMediaType: mediaType).first,
                  let formats = try? await track.load(.formatDescriptions),
                  let format = formats.first else { continue }
            return fourCharacterCode(CMFormatDescriptionGetMediaSubType(format))
        }
        return nil
    }

    static func fourCharacterCode(_ value: FourCharCode) -> String {
        let bytes = [
            UInt8((value >> 24) & 0xFF), UInt8((value >> 16) & 0xFF),
            UInt8((value >> 8) & 0xFF), UInt8(value & 0xFF),
        ]
        let text = String(decoding: bytes, as: UTF8.self)
        return text.trimmingCharacters(in: .whitespaces)
    }
}
