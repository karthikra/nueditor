import Foundation
import Testing
@testable import NUEditor

@Suite("WordCutPlanner")
struct WordCutPlannerTests {
    typealias Word = WordCutPlanner.Word

    private func words(_ selected: Set<Int>) -> [Word] {
        [(0, 10), (11, 20), (21, 30), (31, 40)].enumerated().map {
            Word(startFrame: $0.element.0, endFrame: $0.element.1, selected: selected.contains($0.offset))
        }
    }

    @Test func cutSingleWord() {
        #expect(WordCutPlanner.cutRanges(words: words([1]), clipStart: 0, clipEnd: 100, keepGapFrames: 6)
            == [FrameRange(start: 11, end: 20)])
    }

    @Test func cutContiguousRun() {
        #expect(WordCutPlanner.cutRanges(words: words([1, 2]), clipStart: 0, clipEnd: 100, keepGapFrames: 6)
            == [FrameRange(start: 11, end: 30)])
    }

    @Test func cutNonAdjacentYieldsTwoRanges() {
        #expect(WordCutPlanner.cutRanges(words: words([0, 2]), clipStart: 0, clipEnd: 100, keepGapFrames: 0).count == 2)
    }

    @Test func cutOverlappingTimestamps() {
        let ws = [
            Word(startFrame: 0, endFrame: 10, selected: false),
            Word(startFrame: 9, endFrame: 20, selected: true),
            Word(startFrame: 19, endFrame: 30, selected: false),
        ]
        #expect(WordCutPlanner.cutRanges(words: ws, clipStart: 0, clipEnd: 100, keepGapFrames: 6)
            == [FrameRange(start: 9, end: 20)])
    }

    // A removed word whose audio really ends at 25 (the timestamp said 20). VAD walk must
    // extend the cut to 25 so no fragment of the word remains — regression for "still hear it".
    @Test func vadWalkCoversMistimedTail() {
        let ws = [
            Word(startFrame: 0, endFrame: 10, selected: false),
            Word(startFrame: 11, endFrame: 20, selected: true),
            Word(startFrame: 31, endFrame: 40, selected: false),
        ]
        let speech: (Int) -> Bool = { (0..<10).contains($0) || (11..<25).contains($0) || (31..<40).contains($0) }
        #expect(WordCutPlanner.cutRanges(words: ws, clipStart: 0, clipEnd: 100, keepGapFrames: 6, isSilent: { !speech($0) })
            == [FrameRange(start: 11, end: 25)])
    }

    // The removed word runs straight into the next kept word with no silence between. The walk
    // must stop at the neighbour (frame 31), never crossing into it — regression for over-cut.
    @Test func vadWalkStopsAtKeptNeighbour() {
        let ws = [
            Word(startFrame: 11, endFrame: 20, selected: true),
            Word(startFrame: 31, endFrame: 40, selected: false),
        ]
        #expect(WordCutPlanner.cutRanges(words: ws, clipStart: 0, clipEnd: 100, keepGapFrames: 6, isSilent: { $0 < 11 || $0 >= 40 })
            == [FrameRange(start: 11, end: 31)])
    }

    // The removed word's audio runs 5ms past where the right clip resumes and started 20ms before
    // the left clip ends: both fragments must be measured as sub-frame silence.
    @Test func edgeSilenceMeasuresSubFrameFragment() {
        let s = WordCutPlanner.edgeSilence(
            removedStartSeconds: 0.480, removedEndSeconds: 1.005,
            leftEdgeSourceSeconds: 0.500, rightEdgeSourceSeconds: 1.000
        )
        #expect(abs(s.leadIn - 0.005) < 1e-9)
        #expect(abs(s.leadOut - 0.020) < 1e-9)
    }

    // When the splice already clears the removed word (boundary past its end / before its start),
    // there is no fragment and nothing to silence.
    @Test func edgeSilenceZeroWhenSpliceClearsTheWord() {
        let s = WordCutPlanner.edgeSilence(
            removedStartSeconds: 0.5, removedEndSeconds: 1.0,
            leftEdgeSourceSeconds: 0.48, rightEdgeSourceSeconds: 1.02
        )
        #expect(s == WordCutPlanner.EdgeSilence(leadIn: 0, leadOut: 0))
    }
}

@Suite("CaptionTranscriptMapper — timeline frame → source seconds")
struct SourceSecondsMappingTests {
    @Test func mapsThroughTrimStartAndSpeed() {
        let plain = Fixtures.clip(id: "c", mediaRef: "m", mediaType: .audio, start: 0, duration: 240)
        #expect(CaptionTranscriptMapper.sourceSeconds(ofTimelineFrame: 24, clip: plain, fps: 24) == 1.0)

        let shifted = Fixtures.clip(id: "c", mediaRef: "m", mediaType: .audio, start: 10, duration: 240)
        #expect(CaptionTranscriptMapper.sourceSeconds(ofTimelineFrame: 34, clip: shifted, fps: 24) == 1.0)

        let trimmed = Fixtures.clip(id: "c", mediaRef: "m", mediaType: .audio, start: 0, duration: 240, trimStart: 48)
        #expect(CaptionTranscriptMapper.sourceSeconds(ofTimelineFrame: 0, clip: trimmed, fps: 24) == 2.0)

        let fast = Fixtures.clip(id: "c", mediaRef: "m", mediaType: .audio, start: 0, duration: 240, speed: 2)
        #expect(CaptionTranscriptMapper.sourceSeconds(ofTimelineFrame: 12, clip: fast, fps: 24) == 1.0)
    }
}

@Suite("remove_words — param validation")
@MainActor
struct RemoveWordsParamTests {
    @Test func rejectsEmptyWords() async {
        let h = ToolHarness(timeline: Fixtures.timeline())
        #expect((await h.runRaw("remove_words", args: ["words": [Int]()]).isError))
    }

    @Test func parsesMixedSpans() throws {
        let spans = try ToolExecutor.parseWordSpans([3, [12, 18], 40])
        #expect(spans.count == 3)
        #expect(spans[0].0 == 3 && spans[0].1 == 3)
        #expect(spans[1].0 == 12 && spans[1].1 == 18)
        #expect(spans[2].0 == 40 && spans[2].1 == 40)
    }

    @Test func parsesWordMatches() throws {
        let matches = try ToolExecutor.parseWordMatches(["Um,", " uh ", "HMM"])
        #expect(matches == ["um", "uh", "hmm"])
    }

    @Test func rejectsEmptyMatches() {
        #expect(throws: ToolError.self) {
            _ = try ToolExecutor.parseWordMatches(["..."])
        }
    }
}
