import Foundation
import Synchronization
import Testing
@testable import NUEditor

@Suite("OriginalLocator — find originals by identity")
struct OriginalLocatorTests {

    private final class HashLog: Sendable {
        private let urls = Mutex<[URL]>([])
        var count: Int { urls.withLock { $0.count } }
        func record(_ url: URL) { urls.withLock { $0.append(url) } }
    }

    private struct Fixture {
        let root: URL
        let identity: FootageIdentity

        func volume(_ name: String, uuid: String?, holding contents: Data? = nil) throws -> OriginalLocator.MountedVolume {
            let url = root.appendingPathComponent(name, isDirectory: true)
            if let contents {
                let file = url.appendingPathComponent("DCIM/A001.mov")
                try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
                try contents.write(to: file)
            } else {
                try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            }
            return .init(uuid: uuid, label: name, url: url)
        }

        func cleanUp() { try? FileManager.default.removeItem(at: root) }
    }

    private static let bytes = Data("camera original".utf8)

    /// An identity recorded on drive "UUID-CARD" at DCIM/A001.mov, matching `bytes`.
    private func fixture() throws -> Fixture {
        let root = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let probe = root.appendingPathComponent("probe.mov")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Self.bytes.write(to: probe)
        let (size, modified) = try FootageProbe.fileSizeAndModificationDate(of: probe)
        try FileManager.default.removeItem(at: probe)
        let identity = FootageIdentity(
            checksum: "sha-of-original", fileSizeBytes: size, volumeUUID: "UUID-CARD", volumeLabel: "CARD",
            volumeRelativePath: "DCIM/A001.mov", contentModificationDate: modified
        )
        return Fixture(root: root, identity: identity)
    }

    private func checksum(_ log: HashLog, returning hash: String) -> @Sendable (URL) async throws -> String {
        { url in log.record(url); return hash }
    }

    // A remounted drive comes back at a new mount point; it is the same drive, so no rehash.
    @Test func theSameDriveAtANewMountPointIsFoundWithoutHashing() async throws {
        let f = try fixture()
        defer { f.cleanUp() }
        var identity = f.identity
        let card = try f.volume("CARD 1", uuid: "UUID-CARD", holding: Self.bytes)
        let (_, modified) = try FootageProbe.fileSizeAndModificationDate(of: card.url.appendingPathComponent("DCIM/A001.mov"))
        identity.contentModificationDate = modified
        let log = HashLog()

        let found = await OriginalLocator.locate(identity, on: [card], checksum: checksum(log, returning: "x"))
        #expect(found == card.url.appendingPathComponent("DCIM/A001.mov"))
        #expect(log.count == 0)
    }

    @Test func theSameDriveWithADifferentSizeIsNotTheOriginal() async throws {
        let f = try fixture()
        defer { f.cleanUp() }
        let card = try f.volume("CARD", uuid: "UUID-CARD", holding: Data("re-recorded, longer".utf8))
        let log = HashLog()
        #expect(await OriginalLocator.locate(f.identity, on: [card], checksum: checksum(log, returning: "sha-of-original")) == nil)
    }

    @Test(arguments: [("sha-of-original", true), ("sha-of-something-else", false)])
    func aCopyOnAnotherDriveIsAcceptedOnlyOnAChecksumMatch(hash: String, accepted: Bool) async throws {
        let f = try fixture()
        defer { f.cleanUp() }
        let backup = try f.volume("BACKUP", uuid: "UUID-BACKUP", holding: Self.bytes)
        let log = HashLog()

        let found = await OriginalLocator.locate(f.identity, on: [backup], checksum: checksum(log, returning: hash))
        #expect((found != nil) == accepted)
        #expect(log.count == 1)
    }

    // Hashing a large file costs minutes; a size mismatch rules it out first.
    @Test func aDifferentSizeOnAnotherDriveIsNeverHashed() async throws {
        let f = try fixture()
        defer { f.cleanUp() }
        let backup = try f.volume("BACKUP", uuid: "UUID-BACKUP", holding: Data("different".utf8))
        let log = HashLog()
        #expect(await OriginalLocator.locate(f.identity, on: [backup], checksum: checksum(log, returning: "sha-of-original")) == nil)
        #expect(log.count == 0)
    }

    @Test func anIdentityWithoutAVolumePathCannotBeLocated() async throws {
        let f = try fixture()
        defer { f.cleanUp() }
        var identity = f.identity
        identity.volumeRelativePath = nil
        let card = try f.volume("CARD", uuid: "UUID-CARD", holding: Self.bytes)
        #expect(await OriginalLocator.locate(identity, on: [card], checksum: checksum(HashLog(), returning: "sha-of-original")) == nil)
    }

    @Test func noMountedVolumeHoldingTheFileFindsNothing() async throws {
        let f = try fixture()
        defer { f.cleanUp() }
        let empty = try f.volume("EMPTY", uuid: "UUID-CARD")
        #expect(await OriginalLocator.locate(f.identity, on: [empty], checksum: checksum(HashLog(), returning: "sha-of-original")) == nil)
    }
}
