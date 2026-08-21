import CryptoKit
import Foundation
import Testing
@testable import NUEditor

@Suite("FootageProbe — content identity")
struct FootageProbeTests {

    private func scratchFile(bytes: Int, byte: UInt8 = 0x41) throws -> URL {
        let dir = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("original.mov")
        try Data(repeating: byte, count: bytes).write(to: file)
        return file
    }

    @Test func checksumMatchesAWholeFileHash() async throws {
        let file = try scratchFile(bytes: 4096)
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let expected = SHA256.hash(data: try Data(contentsOf: file))
            .map { String(format: "%02x", $0) }.joined()
        #expect(try await FootageProbe.checksum(of: file) == expected)
    }

    // The hash is streamed in chunks; a file spanning several chunks must hash identically to
    // one that fits in a single read.
    @Test func checksumIsChunkBoundaryIndependent() async throws {
        let file = try scratchFile(bytes: FootageProbe.chunkSize * 2 + 12345)
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let expected = SHA256.hash(data: try Data(contentsOf: file))
            .map { String(format: "%02x", $0) }.joined()
        #expect(try await FootageProbe.checksum(of: file) == expected)
    }

    @Test func identicalBytesUnderDifferentNamesShareOneIdentity() async throws {
        let a = try scratchFile(bytes: 2048)
        let b = a.deletingLastPathComponent().appendingPathComponent("renamed.mov")
        try FileManager.default.copyItem(at: a, to: b)
        defer { try? FileManager.default.removeItem(at: a.deletingLastPathComponent()) }
        #expect(try await FootageProbe.checksum(of: a) == FootageProbe.checksum(of: b))
    }

    @Test func differentBytesDifferentIdentity() async throws {
        let a = try scratchFile(bytes: 2048, byte: 0x41)
        let b = try scratchFile(bytes: 2048, byte: 0x42)
        defer {
            try? FileManager.default.removeItem(at: a.deletingLastPathComponent())
            try? FileManager.default.removeItem(at: b.deletingLastPathComponent())
        }
        #expect(try await FootageProbe.checksum(of: a) != FootageProbe.checksum(of: b))
    }

    @Test func missingFileFailsRatherThanHashingNothing() async throws {
        let missing = URL.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).mov")
        await #expect(throws: (any Error).self) {
            _ = try await FootageProbe.checksum(of: missing)
        }
    }

    @Test func identityCarriesSizeAndVolume() async throws {
        let file = try scratchFile(bytes: 1024)
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let identity = try await FootageProbe.identity(of: file)
        #expect(identity.fileSizeBytes == 1024)
        #expect(!identity.checksum.isEmpty)
        #expect(identity.mountPoint != nil)
    }

    // An external drive comes back at a different mount point, so the half of the location that
    // matters is the path *within* the volume.
    @Test func volumeRelativePathStripsTheMountPoint() {
        #expect(FootageProbe.relativePath(of: "/Volumes/CARD/DCIM/A001.mov", inVolumeAt: "/Volumes/CARD")
            == "DCIM/A001.mov")
        #expect(FootageProbe.relativePath(of: "/Volumes/CARD/DCIM/A001.mov", inVolumeAt: "/Volumes/CARD/")
            == "DCIM/A001.mov")
    }

    @Test func volumeRelativePathRejectsAPathOutsideTheVolume() {
        #expect(FootageProbe.relativePath(of: "/Users/me/a.mov", inVolumeAt: "/Volumes/CARD") == nil)
        #expect(FootageProbe.relativePath(of: "/Volumes/CARD", inVolumeAt: "/Volumes/CARD") == nil)
    }

    @Test func fourCharacterCodesDecodeToCodecNames() {
        #expect(FootageProbe.fourCharacterCode(0x61766331) == "avc1")
        #expect(FootageProbe.fourCharacterCode(0x68766331) == "hvc1")
        #expect(FootageProbe.fourCharacterCode(0x61706373) == "apcs")
    }
}

@Suite("IngestStatus")
struct IngestStatusTests {

    @Test(arguments: [
        IngestStatus.queued, .identifying, .proxying, .uploading, .local,
        .registered("f-123"), .failed("disk went away"),
    ])
    func roundTripsThroughTheManifest(status: IngestStatus) {
        #expect(IngestStatus(serialized: status.serialized) == status)
    }

    // A manifest written by a newer build must not fail the project open.
    @Test func unknownAndMissingStatesDegradeToNone() {
        #expect(IngestStatus(serialized: nil) == IngestStatus.none)
        #expect(IngestStatus(serialized: "archiving") == IngestStatus.none)
    }

    // A quit during hashing leaves an in-flight state on disk; it must be re-queued, not trusted.
    @Test func inFlightStatesAreActive() {
        #expect(IngestStatus.identifying.isActive)
        #expect(IngestStatus.proxying.isActive)
        #expect(IngestStatus.uploading.isActive)
        #expect(!IngestStatus.local.isActive)
        #expect(!IngestStatus.registered("f-1").isActive)
        #expect(!IngestStatus.failed("x").isActive)
    }
}

@Suite("IngestCoordinator — eligibility")
@MainActor
struct IngestEligibilityTests {

    private func asset(type: ClipType) -> MediaAsset {
        MediaAsset(url: URL(fileURLWithPath: "/Volumes/CARD/A001.mov"), type: type, name: "A001")
    }

    @Test func cameraFootageIsIngested() {
        #expect(IngestCoordinator.isEligible(asset(type: .video)))
        #expect(IngestCoordinator.isEligible(asset(type: .audio)))
    }

    // Stills and generated results arrive by other paths; edge ingest is for footage that
    // originates on this machine.
    @Test func stillsAndGeneratedResultsAreNot() {
        #expect(!IngestCoordinator.isEligible(asset(type: .image)))
        let generated = asset(type: .video)
        generated.generationInput = GenerationInput(prompt: "p", model: "m", duration: 4, aspectRatio: "16:9")
        #expect(!IngestCoordinator.isEligible(generated))
    }

    @Test func mediaStillDownloadingIsNot() {
        let pending = asset(type: .video)
        pending.pendingDownloadURL = URL(string: "https://example.com/a.mov")
        #expect(!IngestCoordinator.isEligible(pending))
    }
}
