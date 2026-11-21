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

    // Stage 4: an offline original with a proxy stays playable; only one without a proxy is missing to playback.
    @Test func anOfflineOriginalWithAProxyPlaysFromIt() {
        let editor = EditorViewModel()
        let proxied = MediaAsset(url: URL(fileURLWithPath: "/Volumes/CARD/A001.mov"), type: .video, name: "A001")
        let bare = MediaAsset(url: URL(fileURLWithPath: "/Volumes/CARD/A002.mov"), type: .video, name: "A002")
        editor.mediaAssets = [proxied, bare]
        editor.missingMediaRefs = [proxied.id, bare.id]
        editor.previewProxyURLs = [proxied.id: URL(fileURLWithPath: "/tmp/proxy-a001.mp4")]

        #expect(editor.playbackMissingMediaRefs == [bare.id])
        #expect(editor.isPlayingFromProxy(proxied.id))
        #expect(!editor.isPlayingFromProxy(bare.id))
        #expect(editor.isMediaOffline(proxied.id))
    }

    @Test func exportNamesEachDriveItsOfflineOriginalsAreOn() {
        let editor = EditorViewModel()
        func asset(_ name: String, drive: String?) -> MediaAsset {
            let a = MediaAsset(url: URL(fileURLWithPath: "/Volumes/\(drive ?? "X")/\(name).mov"), type: .video, name: name)
            if let drive { a.footageIdentity = FootageIdentity(checksum: name, fileSizeBytes: 1, volumeUUID: "uuid-\(drive)", volumeLabel: drive) }
            return a
        }
        let a1 = asset("A001", drive: "CARD_A"), a2 = asset("A002", drive: "CARD_A")
        let b1 = asset("B001", drive: "CARD_B"), loose = asset("L001", drive: nil), online = asset("C001", drive: "CARD_C")
        let unused = asset("Z001", drive: "CARD_Z")
        editor.mediaAssets = [a1, a2, b1, loose, online, unused]
        editor.missingMediaRefs = [a1.id, a2.id, b1.id, loose.id, unused.id]
        let timeline = Fixtures.timeline(tracks: [Fixtures.videoTrack(clips: [a1, a2, b1, loose, online].enumerated().map {
            Fixtures.clip(mediaRef: $0.element.id, start: $0.offset * 10, duration: 10)
        })])

        let report = editor.offlineOriginals(usedIn: timeline)
        #expect(report.drives.map(\.label) == ["CARD_A", "CARD_B"])
        #expect(report.drives.map(\.originals) == [2, 1])
        #expect(report.unidentified == 1)
        #expect(report.summary == "Connect “CARD_A” (2 originals), “CARD_B” (1 original) and 1 other offline file.")
    }
}
