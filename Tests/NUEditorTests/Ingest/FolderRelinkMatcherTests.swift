import Foundation
import Synchronization
import Testing
@testable import NUEditor

@Suite("Folder relink — by content, not filename")
struct FolderRelinkMatcherTests {

    private final class HashLog: Sendable {
        private let urls = Mutex<[URL]>([])
        var all: [URL] { urls.withLock { $0 } }
        func record(_ url: URL) { urls.withLock { $0.append(url) } }
    }

    private struct Folder {
        let root: URL

        @discardableResult
        func file(_ path: String, _ contents: String) throws -> URL {
            let url = root.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(contents.utf8).write(to: url)
            return url
        }

        func cleanUp() { try? FileManager.default.removeItem(at: root) }
    }

    private func folder() -> Folder {
        Folder(root: URL.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true))
    }

    private func clip(_ id: String, named name: String, contents: String?) async throws -> FolderRelinkMatcher.OfflineClip {
        guard let contents else { return .init(id: id, filename: name, identity: nil) }
        let probe = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data(contents.utf8).write(to: probe)
        defer { try? FileManager.default.removeItem(at: probe) }
        let identity = FootageIdentity(checksum: try await FootageProbe.checksum(of: probe), fileSizeBytes: contents.utf8.count)
        return .init(id: id, filename: name, identity: identity)
    }

    // Every card has a C0001.MP4; the name must not pick the wrong shot.
    @Test func aRepeatedCameraFilenameRelinksToTheFileWithTheRightBytes() async throws {
        let f = folder()
        defer { f.cleanUp() }
        try f.file("CARD_A/C0001.MP4", "card A shot one")
        let right = try f.file("CARD_B/C0001.MP4", "card B shot one")
        let wanted = try await clip("b1", named: "C0001.MP4", contents: "card B shot one")

        let matches = await FolderRelinkMatcher.match([wanted], in: await FolderRelinkMatcher.scan(f.root))
        #expect(matches["b1"]?.resolvingSymlinksInPath() == right.resolvingSymlinksInPath())
    }

    @Test func aRenamedFileIsFoundByItsContent() async throws {
        let f = folder()
        defer { f.cleanUp() }
        let renamed = try f.file("Selects/Interview_Take1.mov", "the interview take")
        let wanted = try await clip("i1", named: "A001.mov", contents: "the interview take")

        let matches = await FolderRelinkMatcher.match([wanted], in: await FolderRelinkMatcher.scan(f.root))
        #expect(matches["i1"]?.resolvingSymlinksInPath() == renamed.resolvingSymlinksInPath())
    }

    @Test func aSameNamedFileWithDifferentBytesIsRejected() async throws {
        let f = folder()
        defer { f.cleanUp() }
        try f.file("A001.mov", "a re-recorded take")
        let wanted = try await clip("a1", named: "A001.mov", contents: "the original take!")

        #expect(await FolderRelinkMatcher.match([wanted], in: await FolderRelinkMatcher.scan(f.root)).isEmpty)
    }

    // Hashing a large file costs minutes: only exact-size candidates are hashed, and each at most once.
    @Test func onlyExactSizeCandidatesAreHashedAndEachOnlyOnce() async throws {
        let f = folder()
        defer { f.cleanUp() }
        let sameSize = try f.file("X.mov", "12345678")
        try f.file("Y.mov", "a much longer file that no clip can be")
        let first = FolderRelinkMatcher.OfflineClip(id: "1", filename: "A.mov", identity: FootageIdentity(checksum: "h1", fileSizeBytes: 8))
        let second = FolderRelinkMatcher.OfflineClip(id: "2", filename: "B.mov", identity: FootageIdentity(checksum: "h2", fileSizeBytes: 8))
        let log = HashLog()

        _ = await FolderRelinkMatcher.match([first, second], in: await FolderRelinkMatcher.scan(f.root)) { url in
            log.record(url)
            return "neither"
        }
        #expect(log.all.map { $0.resolvingSymlinksInPath() } == [sameSize.resolvingSymlinksInPath()])
    }

    @Test func aClipWithoutAnIdentityFallsBackToItsFilename() async throws {
        let f = folder()
        defer { f.cleanUp() }
        let named = try f.file("deep/A001.mov", "anything")
        let legacy = try await clip("l1", named: "a001.MOV", contents: nil)

        let matches = await FolderRelinkMatcher.match([legacy], in: await FolderRelinkMatcher.scan(f.root))
        #expect(matches["l1"]?.resolvingSymlinksInPath() == named.resolvingSymlinksInPath())
    }
}

@Suite("Folder relink — editor")
@MainActor
struct FolderRelinkEditorTests {
    @Test func relinkFromFolderReconnectsAnIdentifiedClipToItsRenamedFile() async throws {
        let root = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let renamed = root.appendingPathComponent("Selects/Take1.wav")
        try FileManager.default.createDirectory(at: renamed.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 3, count: 2048).write(to: renamed)

        let editor = EditorViewModel()
        let asset = MediaAsset(url: URL(fileURLWithPath: "/Volumes/GONE-\(UUID().uuidString)/A001.wav"), type: .audio, name: "A001")
        asset.footageIdentity = FootageIdentity(checksum: try await FootageProbe.checksum(of: renamed), fileSizeBytes: 2048)
        editor.mediaAssets = [asset]
        editor.missingMediaRefs = [asset.id]

        let result = await editor.relinkOfflineAssets(fromFolder: root)
        #expect(result.relinked == 1 && result.total == 1)
        #expect(asset.url.resolvingSymlinksInPath() == renamed.resolvingSymlinksInPath())
    }
}
