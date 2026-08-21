import Foundation

/// How a word cut should treat the picture at each splice it creates.
enum JumpCutStyle: String, Sendable, CaseIterable {
    /// Leave the cut as-is — correct for anything with motion or a camera change.
    case hard
    /// Cross-dissolve across the join, hiding the jump on a static talking head.
    case soft
}

extension EditorViewModel {
    /// Cross-dissolve every splice where one source was cut against itself — the jump cuts a word
    /// removal leaves behind. Boundaries between different sources are left alone: that is an
    /// intentional cut, not a jump cut.
    ///
    /// Call inside the caller's undo group; softening is part of the same user intent as the cut.
    @discardableResult
    func softenJumpCuts(atFrames splices: [Int], frames: Int = ClipDissolve.defaultFrames) -> Int {
        let edits = jumpCutDissolves(atFrames: splices, frames: frames)
        guard !edits.isEmpty else { return 0 }
        withTimelineSwap(actionName: "Soften Cut") {
            for edit in edits {
                timeline.tracks[edit.trackIndex].clips[edit.clipIndex].dissolveInFrames = edit.frames
            }
        }
        return edits.count
    }

    /// How many of `splices` actually carry a dissolve now — the receipt for a soft cut, since a
    /// boundary without media past the out-point stays hard.
    func dissolvedJoinCount(atFrames splices: [Int]) -> Int {
        let spliceSet = Set(splices)
        var count = 0
        for track in timeline.tracks where track.type == .video {
            for clip in track.clips where clip.dissolveInFrames > 0 && spliceSet.contains(clip.startFrame) {
                count += 1
            }
        }
        return count
    }

    /// Splices whose picture visibly pops and could be softened — a suggestion, never applied on
    /// its own. Samples media off the main actor; the timeline can move while it runs, so callers
    /// re-resolve the boundary (`softenJumpCuts` no-ops on one that is gone).
    func detectJumpCuts(atFrames splices: [Int]) async -> [Int] {
        let candidates = jumpCutDissolves(atFrames: splices, frames: ClipDissolve.defaultFrames)
        guard !candidates.isEmpty else { return [] }
        let capped = candidates.prefix(Self.maxJumpCutProbes)
        if candidates.count > capped.count {
            Log.editor.info("jump-cut probe capped at \(capped.count) of \(candidates.count) boundaries")
        }
        var boundaries: [(frame: Int, boundary: JumpCutDetector.Boundary)] = []
        for edit in capped {
            let clip = timeline.tracks[edit.trackIndex].clips[edit.clipIndex]
            guard let boundary = jumpCutBoundary(into: clip, trackIndex: edit.trackIndex) else { continue }
            boundaries.append((clip.startFrame, boundary))
        }
        var popping: [Int] = []
        for (frame, boundary) in boundaries where await JumpCutDetector.isJumpCut(at: boundary) == true {
            popping.append(frame)
        }
        return popping
    }

    /// Probing decodes two frames per boundary; a long selection must not spawn one reader per cut.
    private static let maxJumpCutProbes = 12

    /// The frames either side of `clip`'s in-point, in its source's own seconds.
    private func jumpCutBoundary(into clip: Clip, trackIndex: Int) -> JumpCutDetector.Boundary? {
        let ordered = timeline.tracks[trackIndex].clips.sorted { $0.startFrame < $1.startFrame }
        guard let position = ordered.firstIndex(where: { $0.id == clip.id }), position > 0 else { return nil }
        let previous = ordered[position - 1]
        guard let outgoingURL = mediaResolver.resolveURL(for: previous.mediaRef),
              let incomingURL = mediaResolver.resolveURL(for: clip.mediaRef) else { return nil }
        let fps = timeline.fps
        return JumpCutDetector.Boundary(
            outgoingURL: outgoingURL,
            outgoingSeconds: CaptionTranscriptMapper.sourceSeconds(ofTimelineFrame: clip.startFrame - 1, clip: previous, fps: fps),
            incomingURL: incomingURL,
            incomingSeconds: CaptionTranscriptMapper.sourceSeconds(ofTimelineFrame: clip.startFrame, clip: clip, fps: fps)
        )
    }

    /// Boundaries the splices land on that can carry a dissolve, resolved before any mutation so a
    /// no-op never opens an undo step.
    private func jumpCutDissolves(
        atFrames splices: [Int],
        frames: Int
    ) -> [(trackIndex: Int, clipIndex: Int, frames: Int)] {
        guard frames > 0, !splices.isEmpty else { return [] }
        let spliceSet = Set(splices)
        var edits: [(trackIndex: Int, clipIndex: Int, frames: Int)] = []
        for ti in timeline.tracks.indices where timeline.tracks[ti].type == .video {
            let ordered = timeline.tracks[ti].clips
                .enumerated()
                .sorted { $0.element.startFrame < $1.element.startFrame }
            for (position, entry) in ordered.enumerated() where position > 0 {
                let previous = ordered[position - 1].element
                let clip = entry.element
                guard spliceSet.contains(clip.startFrame),
                      previous.endFrame == clip.startFrame,
                      previous.mediaRef == clip.mediaRef,
                      clip.dissolveInFrames == 0 else { continue }
                let length = min(frames, ClipDissolve.maxDissolveFrames(into: clip, previous: previous))
                guard length > 0 else { continue }
                edits.append((ti, entry.offset, length))
            }
        }
        return edits
    }
}
