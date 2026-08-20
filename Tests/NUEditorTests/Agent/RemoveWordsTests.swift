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
