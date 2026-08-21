import Foundation
import Testing
@testable import NUEditor

@Suite("EditorViewModel.softenJumpCuts")
@MainActor
struct SoftenJumpCutsTests {

    /// Two fragments of one source abutting at frame 100 — the shape a word cut leaves behind.
    private func editor(
        secondMediaRef: String = "m",
        firstTrimEnd: Int = 60,
        trackType: ClipType = .video
    ) -> EditorViewModel {
        let a = Fixtures.clip(id: "a", mediaRef: "m", mediaType: trackType, start: 0, duration: 100, trimEnd: firstTrimEnd)
        let b = Fixtures.clip(id: "b", mediaRef: secondMediaRef, mediaType: trackType, start: 100, duration: 100, trimStart: 160)
        let track = trackType == .video
            ? Fixtures.videoTrack(clips: [a, b])
            : Fixtures.audioTrack(clips: [a, b])
        let vm = EditorViewModel()
        vm.timeline = Fixtures.timeline(tracks: [track])
        return vm
    }

    private func dissolve(_ vm: EditorViewModel, clipId: String) -> Int {
        vm.timeline.tracks.flatMap(\.clips).first { $0.id == clipId }?.dissolveInFrames ?? -1
    }

    @Test func installsADissolveOnTheIncomingClipAtASplice() {
        let vm = editor()
        #expect(vm.softenJumpCuts(atFrames: [100], frames: 8) == 1)
        #expect(dissolve(vm, clipId: "b") == 8)
        #expect(dissolve(vm, clipId: "a") == 0)
    }

    // A boundary between two different sources is an intentional cut, not a jump cut.
    @Test func leavesBoundariesBetweenDifferentSourcesAlone() {
        let vm = editor(secondMediaRef: "other")
        #expect(vm.softenJumpCuts(atFrames: [100], frames: 8) == 0)
        #expect(dissolve(vm, clipId: "b") == 0)
    }

    @Test func ignoresFramesThatAreNotClipBoundaries() {
        let vm = editor()
        #expect(vm.softenJumpCuts(atFrames: [50], frames: 8) == 0)
    }

    @Test func audioTracksCarryNoDissolve() {
        let vm = editor(trackType: .audio)
        #expect(vm.softenJumpCuts(atFrames: [100], frames: 8) == 0)
    }

    // No handle past the out-point → nothing to dissolve from, and no undo step for a no-op.
    @Test func noHandleMeansNoDissolveAndNoUndoStep() {
        let vm = editor(firstTrimEnd: 0)
        let um = UndoManager()
        vm.undo.attach(um)
        #expect(vm.softenJumpCuts(atFrames: [100], frames: 8) == 0)
        #expect(um.canUndo == false)
    }

    @Test func requestIsClampedToTheAvailableHandle() {
        let vm = editor(firstTrimEnd: 5)
        #expect(vm.softenJumpCuts(atFrames: [100], frames: 20) == 1)
        #expect(dissolve(vm, clipId: "b") == 5)
    }

    @Test func aBoundaryAlreadySoftenedIsNotTouchedAgain() {
        let vm = editor()
        #expect(vm.softenJumpCuts(atFrames: [100], frames: 8) == 1)
        #expect(vm.softenJumpCuts(atFrames: [100], frames: 12) == 0)
        #expect(dissolve(vm, clipId: "b") == 8)
    }
}
