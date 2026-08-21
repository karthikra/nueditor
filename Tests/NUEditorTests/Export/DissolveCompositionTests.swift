import AVFoundation
import Testing
@testable import NUEditor

/// The dissolve end to end through the real composition: the outgoing tail must be inserted as
/// its own composition track and composited above the incoming clip for exactly the join window.
@Suite("CompositionBuilder.build — cross-dissolve")
struct DissolveCompositionTests {

    private let renderSize = CGSize(width: 320, height: 180)

    /// Two fragments of one 4s source abutting at frame 30 — the shape a word cut leaves.
    private func timeline(dissolveFrames: Int) -> Timeline {
        let outgoing = Fixtures.clip(id: "a", mediaRef: "video", start: 0, duration: 30, trimEnd: 90)
        var incoming = Fixtures.clip(id: "b", mediaRef: "video", start: 30, duration: 30, trimStart: 60, trimEnd: 30)
        incoming.dissolveInFrames = dissolveFrames
        return Fixtures.timeline(fps: 30, tracks: [Fixtures.videoTrack(clips: [outgoing, incoming])])
    }

    private func build(_ timeline: Timeline, url: URL) async throws -> CompositionResult {
        try await CompositionBuilder.build(
            timeline: timeline,
            resolveURL: { $0 == "video" ? url : nil },
            renderSize: renderSize
        )
    }

    private func fixtureVideo() async throws -> URL {
        try await FixtureVideo.write(
            scenes: [FixtureVideo.Scene(rgb: (255, 0, 0), seconds: 4)],
            fps: 30,
            size: 64
        )
    }

    @Test func tailIsInsertedOnItsOwnTrackFromTheOutgoingOutPoint() async throws {
        let url = try await fixtureVideo()
        defer { try? FileManager.default.removeItem(at: url) }
        let result = try await build(timeline(dissolveFrames: 6), url: url)

        let tailId = ClipDissolve.tailId(for: "b")
        let mapping = try #require(result.trackMappings.first { mapping in
            guard mapping.isVideo, case .timeline(_, let clipIds) = mapping.kind else { return false }
            return clipIds == [tailId]
        })
        // Its own track: the lane's clips would otherwise overlap in composition time.
        #expect(mapping.compositionTrack.trackID != result.trackMappings.first { m in
            guard m.isVideo, case .timeline(_, let ids) = m.kind else { return false }
            return ids?.contains("a") == true
        }?.compositionTrack.trackID)

        let segment = try #require(mapping.compositionTrack.segments.first { !$0.isEmpty })
        // Plays from the outgoing clip's out-point (30 frames at 30fps = 1s), for 6 frames.
        #expect(abs(segment.timeMapping.source.start.seconds - 1.0) < 0.02)
        #expect(abs(segment.timeMapping.target.start.seconds - 1.0) < 0.02)
        #expect(abs(segment.timeMapping.target.duration.seconds - 6.0 / 30) < 0.02)
    }

    @Test func tailCompositesAboveTheIncomingClipForTheJoinWindow() async throws {
        let url = try await fixtureVideo()
        defer { try? FileManager.default.removeItem(at: url) }
        let result = try await build(timeline(dissolveFrames: 6), url: url)

        let tailId = ClipDissolve.tailId(for: "b")
        let instructions = result.videoComposition.instructions.compactMap { $0 as? CompositorInstruction }
        let joinStart = CMTime(value: 30, timescale: 30)
        let during = try #require(instructions.first { $0.timeRange.containsTime(joinStart) })
        let ids = during.layers.map(\.clip.id)
        let tailIndex = try #require(ids.firstIndex(of: tailId))
        let incomingIndex = try #require(ids.firstIndex(of: "b"))
        #expect(tailIndex > incomingIndex, "the tail must render over the incoming clip, got \(ids)")

        // And it is gone once the dissolve ends.
        let after = try #require(instructions.first { $0.timeRange.containsTime(CMTime(value: 40, timescale: 30)) })
        #expect(!after.layers.map(\.clip.id).contains(tailId))
    }

    @Test func noDissolveLeavesTheCompositionUntouched() async throws {
        let url = try await fixtureVideo()
        defer { try? FileManager.default.removeItem(at: url) }
        let result = try await build(timeline(dissolveFrames: 0), url: url)

        let tailId = ClipDissolve.tailId(for: "b")
        #expect(!result.trackMappings.contains { mapping in
            guard case .timeline(_, let clipIds) = mapping.kind else { return false }
            return clipIds?.contains(tailId) == true
        })
        let instructions = result.videoComposition.instructions.compactMap { $0 as? CompositorInstruction }
        #expect(!instructions.flatMap { $0.layers.map(\.clip.id) }.contains(tailId))
    }
}
