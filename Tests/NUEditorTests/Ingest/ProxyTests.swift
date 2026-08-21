import AVFoundation
import Foundation
import Testing
@testable import NUEditor

@Suite("ProxyBuilder — geometry")
struct ProxyGeometryTests {

    @Test func scalesTheLongestEdgeAndKeepsAspect() {
        let size = ProxyBuilder.proxySize(for: CGSize(width: 3840, height: 2160), maxEdge: 1280)
        #expect(size == CGSize(width: 1280, height: 720))
    }

    // A vertical original proxies to 1280 tall, not 1280 wide — the cap is on the longest edge.
    @Test func verticalFootageIsNotRotatedOrCropped() {
        let size = ProxyBuilder.proxySize(for: CGSize(width: 1080, height: 1920), maxEdge: 1280)
        #expect(size == CGSize(width: 720, height: 1280))
    }

    @Test func neverUpscalesAFootageSmallerThanTheProxy() {
        let size = ProxyBuilder.proxySize(for: CGSize(width: 640, height: 360), maxEdge: 1280)
        #expect(size == CGSize(width: 640, height: 360))
    }

    // H.264 requires even dimensions; odd source sizes must not produce an unencodable proxy.
    @Test func dimensionsAreAlwaysEven() {
        for source in [CGSize(width: 1919, height: 1079), CGSize(width: 999, height: 333)] {
            let size = ProxyBuilder.proxySize(for: source, maxEdge: 854)
            #expect(Int(size.width) % 2 == 0, "odd width for \(source)")
            #expect(Int(size.height) % 2 == 0, "odd height for \(source)")
        }
    }

    @Test func fitTransformScalesIntoTheProxyFrame() {
        let transform = ProxyBuilder.fitTransform(
            displaySize: CGSize(width: 3840, height: 2160),
            preferredTransform: .identity,
            into: CGSize(width: 1280, height: 720)
        )
        let corner = CGPoint(x: 3840, y: 2160).applying(transform)
        #expect(abs(corner.x - 1280) < 0.5)
        #expect(abs(corner.y - 720) < 0.5)
    }

    @Test func derivativeKindsMapToTheTowerContract() {
        #expect(ProxyKind.vlm.backendDerivative == .vlmProxy)
        #expect(ProxyKind.preview.backendDerivative == .previewProxy)
        #expect(ProxyKind.audio.backendDerivative == .audio)
        #expect(ProxyKind.audio.fileExtension == "wav")
        #expect(ProxyKind.vlm.fileExtension == "mp4")
        // The VLM proxy is picture-only; the tower gets speech from the WAV.
        #expect(!ProxyKind.vlm.includesAudio)
        #expect(ProxyKind.vlm.frameRate == 5)
    }
}

@Suite("ProxyBuilder — encoding")
struct ProxyEncodingTests {

    @Test func previewProxyIsDownscaledAndPlayable() async throws {
        let source = try await FixtureVideo.write(
            scenes: [FixtureVideo.Scene(rgb: (0, 128, 255), seconds: 1)], fps: 30, size: 1920
        )
        let dir = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: source)
            try? FileManager.default.removeItem(at: dir)
        }
        let destination = dir.appendingPathComponent("preview.mp4")
        try await ProxyBuilder.build(.preview, from: source, to: destination)

        let asset = AVURLAsset(url: destination)
        let track = try #require(try await asset.loadTracks(withMediaType: .video).first)
        let size = try await track.load(.naturalSize)
        #expect(max(size.width, size.height) <= 1280)
        // The proxy must stand in for the original, so its duration has to match it.
        let sourceDuration = try await AVURLAsset(url: source).load(.duration).seconds
        let proxyDuration = try await asset.load(.duration).seconds
        #expect(abs(proxyDuration - sourceDuration) < 0.1)
    }

    @Test func vlmProxyIsSparseAndSilent() async throws {
        let source = try await FixtureVideo.write(
            scenes: [FixtureVideo.Scene(rgb: (255, 0, 0), seconds: 2)], fps: 30, size: 640
        )
        let dir = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: source)
            try? FileManager.default.removeItem(at: dir)
        }
        let destination = dir.appendingPathComponent("vlm.mp4")
        try await ProxyBuilder.build(.vlm, from: source, to: destination)

        let asset = AVURLAsset(url: destination)
        let track = try #require(try await asset.loadTracks(withMediaType: .video).first)
        let rate = try await track.load(.nominalFrameRate)
        #expect(rate <= 6, "vlm proxy should run at ~5 fps, got \(rate)")
        #expect(try await asset.loadTracks(withMediaType: .audio).isEmpty)
        // Smaller than the original by a wide margin — that reduction is the whole point.
        let sourceBytes = try FootageProbe.fileSize(of: source)
        let proxyBytes = try FootageProbe.fileSize(of: destination)
        #expect(proxyBytes < sourceBytes)
    }

    @Test func footageWithoutPictureFailsLoudly() async throws {
        let dir = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let empty = dir.appendingPathComponent("notmedia.mp4")
        try Data("not a movie".utf8).write(to: empty)
        await #expect(throws: (any Error).self) {
            try await ProxyBuilder.build(.preview, from: empty, to: dir.appendingPathComponent("out.mp4"))
        }
    }
}

@Suite("ProxyCache")
struct ProxyCacheTests {

    private func scratchCache(budgetBytes: Int64 = ProxyCache.defaultBudgetBytes) throws -> (ProxyCache, URL) {
        let dir = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return (ProxyCache(directory: dir, budgetBytes: budgetBytes), dir)
    }

    private func stage(_ cache: ProxyCache, checksum: String, kind: ProxyKind, bytes: Int) async throws -> URL {
        let staged = try await cache.stagingURL(checksum: checksum, kind: kind)
        try Data(repeating: 0x7A, count: bytes).write(to: staged)
        return try await cache.install(staged, checksum: checksum, kind: kind)
    }

    @Test func proxiesAreAddressedByContentNotName() async throws {
        let (cache, dir) = try scratchCache()
        defer { try? FileManager.default.removeItem(at: dir) }
        _ = try await stage(cache, checksum: "abc123", kind: .preview, bytes: 64)
        #expect(await cache.existing(checksum: "abc123", kind: .preview) != nil)
        // Same bytes under any other name resolve to the same proxy; different bytes do not.
        #expect(await cache.existing(checksum: "def456", kind: .preview) == nil)
        #expect(await cache.existing(checksum: "abc123", kind: .vlm) == nil)
    }

    @Test func installReplacesAnExistingProxyAtomically() async throws {
        let (cache, dir) = try scratchCache()
        defer { try? FileManager.default.removeItem(at: dir) }
        _ = try await stage(cache, checksum: "abc", kind: .preview, bytes: 16)
        let replaced = try await stage(cache, checksum: "abc", kind: .preview, bytes: 128)
        #expect(try FootageProbe.fileSize(of: replaced) == 128)
        #expect(await cache.totalBytes() == 128)
    }

    // A staged file must never look like a cache hit or count toward the budget.
    @Test func stagingFilesAreNotProxies() async throws {
        let (cache, dir) = try scratchCache()
        defer { try? FileManager.default.removeItem(at: dir) }
        let staged = try await cache.stagingURL(checksum: "abc", kind: .preview)
        try Data(repeating: 1, count: 999).write(to: staged)
        #expect(await cache.existing(checksum: "abc", kind: .preview) == nil)
        #expect(await cache.totalBytes() == 0)
    }

    @Test func evictionFreesBytesDownToTheBudget() async throws {
        let (cache, dir) = try scratchCache(budgetBytes: 1500)
        defer { try? FileManager.default.removeItem(at: dir) }
        for (index, checksum) in ["aaa", "bbb", "ccc"].enumerated() {
            _ = try await stage(cache, checksum: checksum, kind: .preview, bytes: 1000)
            // Distinct ages so "coldest first" is well defined rather than timing luck.
            let url = await cache.url(checksum: checksum, kind: .preview)
            try FileManager.default.setAttributes(
                [.modificationDate: Date(timeIntervalSince1970: Double(index) * 100)],
                ofItemAtPath: url.path
            )
        }
        let freed = await cache.evictToBudget()
        #expect(freed >= 1000)
        #expect(await cache.totalBytes() <= 1500)
        // The coldest went first; the most recently used survived.
        #expect(await cache.existing(checksum: "aaa", kind: .preview) == nil)
        #expect(await cache.existing(checksum: "ccc", kind: .preview) != nil)
    }

    // Footage in an open project must survive an import that blows the budget.
    @Test func pinnedProxiesAreNeverEvicted() async throws {
        let (cache, dir) = try scratchCache(budgetBytes: 500)
        defer { try? FileManager.default.removeItem(at: dir) }
        _ = try await stage(cache, checksum: "pinned", kind: .preview, bytes: 1000)
        let url = await cache.url(checksum: "pinned", kind: .preview)
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: 0)], ofItemAtPath: url.path
        )
        _ = try await stage(cache, checksum: "cold", kind: .preview, bytes: 1000)
        await cache.pin(checksums: ["pinned"])

        await cache.evictToBudget()
        #expect(await cache.existing(checksum: "pinned", kind: .preview) != nil)
        #expect(await cache.existing(checksum: "cold", kind: .preview) == nil)
    }

    @Test func aCacheUnderBudgetEvictsNothing() async throws {
        let (cache, dir) = try scratchCache()
        defer { try? FileManager.default.removeItem(at: dir) }
        _ = try await stage(cache, checksum: "abc", kind: .preview, bytes: 128)
        #expect(await cache.evictToBudget() == 0)
        #expect(await cache.existing(checksum: "abc", kind: .preview) != nil)
    }
}
