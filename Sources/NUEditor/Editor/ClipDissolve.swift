import Foundation

/// A cross-dissolve at a clip boundary: the outgoing clip's tail — media past its out-point —
/// overlays the incoming clip's head and fades out over it. The timeline itself stays
/// non-overlapping, so the ripple, trim, and sync rules are untouched; only the render adds a layer.
///
/// Single source of truth for the composition insert pass and the layer plan, so the tail that
/// renders is exactly the tail that was inserted.
enum ClipDissolve {
    /// Longest dissolve worth offering at a jump cut; past this it reads as a fade, not a repair.
    static let maxFrames = 30

    /// Default length for a word-cut jump-cut repair — short enough to read as a soft cut.
    static let defaultFrames = 8

    static func tailId(for clipId: String) -> String { "\(clipId)#dissolve" }

    /// Source frames still available past `previous`'s out-point, in timeline frames.
    static func availableTailFrames(after previous: Clip) -> Int {
        if previous.mediaType == .image { return maxFrames }
        guard previous.speed > 0 else { return 0 }
        return Int(Double(previous.trimEndFrame) / previous.speed)
    }

    /// Longest dissolve this boundary can actually render, 0 when it cannot dissolve at all.
    static func maxDissolveFrames(into clip: Clip, previous: Clip?) -> Int {
        guard let previous, canDissolve(into: clip, previous: previous) else { return 0 }
        return min(maxFrames, clip.durationFrames, availableTailFrames(after: previous))
    }

    /// The overlay tail for `clip`'s dissolve-in, or nil when the boundary cannot dissolve.
    /// `previous` is the clip immediately before it in the same lane.
    static func tail(into clip: Clip, previous: Clip?) -> Clip? {
        guard clip.dissolveInFrames > 0, let previous else { return nil }
        let frames = min(clip.dissolveInFrames, maxDissolveFrames(into: clip, previous: previous))
        guard frames > 0 else { return nil }

        var tail = previous
        tail.id = tailId(for: clip.id)
        tail.startFrame = clip.startFrame
        tail.durationFrames = frames
        // Play the frames just past the outgoing clip's out-point.
        tail.trimStartFrame = previous.trimStartFrame + previous.sourceFramesConsumed
        tail.trimEndFrame = max(0, previous.trimEndFrame - Int((Double(frames) * previous.speed).rounded()))
        // The incoming clip is opaque underneath, so fading the whole overlay out *is* the dissolve.
        tail.fadeInFrames = 0
        tail.fadeOutFrames = frames
        tail.fadeOutInterpolation = .linear
        // Keyframe tracks are indexed from the outgoing clip's own start; they don't survive the move.
        tail.opacityTrack = nil
        tail.positionTrack = nil
        tail.scaleTrack = nil
        tail.rotationTrack = nil
        tail.cropTrack = nil
        tail.volumeTrack = nil
        tail.linkGroupId = nil
        tail.captionGroupId = nil
        tail.multicamGroupId = nil
        tail.dissolveInFrames = 0
        // Video-only overlay: the tail never contributes audio.
        tail.audioLeadInSeconds = 0
        tail.audioLeadOutSeconds = 0
        return tail
    }

    private static func canDissolve(into clip: Clip, previous: Clip) -> Bool {
        previous.endFrame == clip.startFrame
            && clip.durationFrames > 0
            && previous.durationFrames > 0
            && dissolvableMediaType(clip.mediaType)
            && dissolvableMediaType(previous.mediaType)
    }

    /// Text renders from instructions and a nest needs its children flattened — neither can supply a tail.
    private static func dissolvableMediaType(_ type: ClipType) -> Bool {
        type != .text && type != .sequence && type != .audio
    }
}
