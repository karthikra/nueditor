import Foundation
import Testing
@testable import NUEditor

@Suite("ClipDissolve — tail geometry")
struct ClipDissolveTests {

    /// Outgoing clip: 100 frames of source consumed, 50 frames of handle left past the out-point.
    private func boundary(
        dissolve: Int,
        outgoingTrimStart: Int = 0,
        outgoingTrimEnd: Int = 50,
        outgoingSpeed: Double = 1.0,
        incomingDuration: Int = 100
    ) -> (previous: Clip, clip: Clip) {
        let previous = Fixtures.clip(
            id: "a", mediaRef: "m", start: 0, duration: 100,
            trimStart: outgoingTrimStart, trimEnd: outgoingTrimEnd, speed: outgoingSpeed
        )
        var clip = Fixtures.clip(id: "b", mediaRef: "m", start: 100, duration: incomingDuration, trimStart: 150)
        clip.dissolveInFrames = dissolve
        return (previous, clip)
    }

    @Test func tailPlaysTheFramesPastTheOutgoingOutPoint() throws {
        let (previous, clip) = boundary(dissolve: 8, outgoingTrimStart: 20)
        let tail = try #require(ClipDissolve.tail(into: clip, previous: previous))
        // Out-point in source = trimStart + frames consumed.
        #expect(tail.trimStartFrame == 120)
        #expect(tail.startFrame == clip.startFrame)
        #expect(tail.durationFrames == 8)
        #expect(tail.mediaRef == previous.mediaRef)
    }

    @Test func tailFadesFromOpaqueToClearAcrossTheDissolve() throws {
        let (previous, clip) = boundary(dissolve: 8)
        let tail = try #require(ClipDissolve.tail(into: clip, previous: previous))
        #expect(tail.fadeInFrames == 0)
        #expect(tail.fadeOutFrames == 8)
        #expect(tail.opacityAt(frame: tail.startFrame) == 1.0)
        #expect(tail.opacityAt(frame: tail.startFrame + 4) == 0.5)
        #expect(tail.opacityAt(frame: tail.endFrame) == 0.0)
    }

    @Test func tailIdIsDerivedFromTheIncomingClip() throws {
        let (previous, clip) = boundary(dissolve: 4)
        let tail = try #require(ClipDissolve.tail(into: clip, previous: previous))
        #expect(tail.id == ClipDissolve.tailId(for: clip.id))
        #expect(tail.id != previous.id)
    }

    // The tail is an overlay, not a second copy of the clip: it must not re-run keyframed
    // animation indexed from the outgoing clip's own start, nor claim its link group.
    @Test func tailDropsKeyframeTracksAndLinkage() throws {
        var (previous, clip) = boundary(dissolve: 6)
        previous.opacityTrack = KeyframeTrack<Double>()
        previous.linkGroupId = "group-1"
        clip.dissolveInFrames = 6
        let tail = try #require(ClipDissolve.tail(into: clip, previous: previous))
        #expect(tail.opacityTrack == nil)
        #expect(tail.positionTrack == nil)
        #expect(tail.linkGroupId == nil)
        #expect(tail.dissolveInFrames == 0)
    }

    @Test func noTailWithoutADissolve() {
        let (previous, clip) = boundary(dissolve: 0)
        #expect(ClipDissolve.tail(into: clip, previous: previous) == nil)
    }

    @Test func noTailWhenTheClipsDoNotAbut() {
        var (previous, clip) = boundary(dissolve: 8)
        clip.startFrame = previous.endFrame + 1   // a gap, not a cut
        #expect(ClipDissolve.tail(into: clip, previous: previous) == nil)
    }

    @Test func noTailAtTheStartOfATrack() {
        let (_, clip) = boundary(dissolve: 8)
        #expect(ClipDissolve.tail(into: clip, previous: nil) == nil)
    }

    // Without media past the out-point there is nothing to dissolve from; a hard cut is correct.
    @Test func noTailWhenTheOutgoingClipHasNoHandle() {
        let (previous, clip) = boundary(dissolve: 8, outgoingTrimEnd: 0)
        #expect(ClipDissolve.maxDissolveFrames(into: clip, previous: previous) == 0)
        #expect(ClipDissolve.tail(into: clip, previous: previous) == nil)
    }

    @Test func tailIsClampedToTheAvailableHandle() throws {
        let (previous, clip) = boundary(dissolve: 12, outgoingTrimEnd: 5)
        let tail = try #require(ClipDissolve.tail(into: clip, previous: previous))
        #expect(tail.durationFrames == 5)
    }

    @Test func tailNeverOutlastsTheIncomingClip() throws {
        let (previous, clip) = boundary(dissolve: 12, incomingDuration: 3)
        let tail = try #require(ClipDissolve.tail(into: clip, previous: previous))
        #expect(tail.durationFrames == 3)
    }

    // A retimed outgoing clip consumes source faster: both the out-point and the handle it
    // leaves behind are in source frames, not timeline frames.
    @Test func retimedOutgoingClipMapsThroughSpeed() throws {
        let (previous, clip) = boundary(dissolve: 8, outgoingTrimEnd: 20, outgoingSpeed: 2.0)
        let tail = try #require(ClipDissolve.tail(into: clip, previous: previous))
        #expect(tail.trimStartFrame == 200)       // 100 timeline frames at 2× = 200 source frames
        #expect(tail.durationFrames == 8)         // 20 source frames of handle = 10 timeline frames
        #expect(ClipDissolve.availableTailFrames(after: previous) == 10)
    }

    @Test func textAndNestBoundariesCannotDissolve() {
        var (previous, clip) = boundary(dissolve: 8)
        previous.mediaType = .text
        #expect(ClipDissolve.tail(into: clip, previous: previous) == nil)
        previous.mediaType = .sequence
        #expect(ClipDissolve.tail(into: clip, previous: previous) == nil)
        previous.mediaType = .video
        clip.mediaType = .audio
        #expect(ClipDissolve.tail(into: clip, previous: previous) == nil)
    }
}

@Suite("RippleEngine.spliceFrames")
struct SpliceFramesTests {

    @Test func singleRangeSplicesAtItsStart() {
        #expect(RippleEngine.spliceFrames(after: [FrameRange(start: 40, end: 60)]) == [40])
    }

    // Each later splice shifts left by everything already removed before it.
    @Test func laterSplicesShiftByEarlierRemovals() {
        let ranges = [FrameRange(start: 10, end: 20), FrameRange(start: 50, end: 55), FrameRange(start: 80, end: 100)]
        #expect(RippleEngine.spliceFrames(after: ranges) == [10, 40, 65])
    }

    @Test func adjacentRangesMergeIntoOneSplice() {
        #expect(RippleEngine.spliceFrames(after: [FrameRange(start: 10, end: 20), FrameRange(start: 20, end: 30)]) == [10])
    }

    @Test func unorderedInputSplicesInTimelineOrder() {
        let ranges = [FrameRange(start: 80, end: 100), FrameRange(start: 10, end: 20)]
        #expect(RippleEngine.spliceFrames(after: ranges) == [10, 70])
    }

    @Test func noRangesNoSplices() {
        #expect(RippleEngine.spliceFrames(after: []).isEmpty)
    }
}
