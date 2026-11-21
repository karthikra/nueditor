import Foundation
import Testing
@testable import NUEditor

@Suite("Relink by identity — originals follow their drive")
@MainActor
struct VolumeRelinkTests {

    private func tempFile(_ name: String, contents: Data) throws -> URL {
        let dir = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(name)
        try contents.write(to: url)
        return url
    }

    @Test func anOfflineOriginalIsReconnectedWhereItsBytesAreMountedNow() async throws {
        let original = try tempFile("A001.wav", contents: Data(repeating: 7, count: 4096))
        defer { try? FileManager.default.removeItem(at: original.deletingLastPathComponent()) }
        let identity = try await FootageProbe.identity(of: original)
        try #require(identity.volumeRelativePath != nil)

        let editor = EditorViewModel()
        let stale = URL(fileURLWithPath: "/Volumes/GONE-\(UUID().uuidString)/A001.wav")
        let asset = MediaAsset(url: stale, type: .audio, name: "A001")
        asset.footageIdentity = identity
        editor.mediaAssets.append(asset)
        editor.missingMediaRefs = [asset.id]

        editor.relinkOfflineOriginals()
        await editor.identityRelinkTask?.value
        #expect(asset.url.standardizedFileURL.resolvingSymlinksInPath() == original.standardizedFileURL.resolvingSymlinksInPath())
    }

    @Test func anOfflineOriginalWithNoMountedCopyStaysWhereItWas() async throws {
        let editor = EditorViewModel()
        let stale = URL(fileURLWithPath: "/Volumes/GONE-\(UUID().uuidString)/A001.mov")
        let asset = MediaAsset(url: stale, type: .video, name: "A001")
        asset.footageIdentity = FootageIdentity(
            checksum: "abc", fileSizeBytes: 10, volumeUUID: UUID().uuidString, volumeRelativePath: "DCIM/\(UUID().uuidString).mov"
        )
        editor.mediaAssets.append(asset)
        editor.missingMediaRefs = [asset.id]

        editor.relinkOfflineOriginals()
        await editor.identityRelinkTask?.value
        #expect(asset.url == stale)
        #expect(editor.missingMediaRefs.contains(asset.id))
    }

    @Test func unmountingADriveTakesOnlyItsOriginalsOffline() {
        let editor = EditorViewModel()
        let onCard = MediaAsset(url: URL(fileURLWithPath: "/Volumes/CARD/DCIM/A001.mov"), type: .video, name: "A001")
        let onCardTwo = MediaAsset(url: URL(fileURLWithPath: "/Volumes/CARD 2/DCIM/A002.mov"), type: .video, name: "A002")
        editor.mediaAssets = [onCard, onCardTwo]

        editor.markOriginalsOffline(onVolumeAt: URL(fileURLWithPath: "/Volumes/CARD", isDirectory: true))
        #expect(editor.missingMediaRefs == [onCard.id])
    }
}
