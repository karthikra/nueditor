import Foundation
import Testing
@testable import NUEditor

@Suite("TranscriptCorrections")
struct TranscriptCorrectionsTests {

    private func corrections(_ text: String = "Levi's", at seconds: Double = 4.20) -> TranscriptCorrections {
        var c = TranscriptCorrections()
        c.set(text, mediaRef: "m", startSeconds: seconds)
        return c
    }

    @Test func returnsTheFixForTheCorrectedWord() {
        #expect(corrections().text(mediaRef: "m", startSeconds: 4.20) == "Levi's")
    }

    @Test func doesNotLeakAcrossMedia() {
        #expect(corrections().text(mediaRef: "other", startSeconds: 4.20) == nil)
    }

    // A re-transcribe can nudge a word a few ms; the fix must survive that, but not migrate
    // to a neighbouring word.
    @Test func matchesWithinToleranceOnly() {
        let c = corrections()
        #expect(c.text(mediaRef: "m", startSeconds: 4.24) == "Levi's")
        #expect(c.text(mediaRef: "m", startSeconds: 4.50) == nil)
    }

    @Test func nearestCorrectionWinsWhenTwoAreClose() {
        var c = TranscriptCorrections()
        c.set("first", mediaRef: "m", startSeconds: 1.00)
        c.set("second", mediaRef: "m", startSeconds: 1.12)
        #expect(c.text(mediaRef: "m", startSeconds: 1.11) == "second")
        #expect(c.text(mediaRef: "m", startSeconds: 1.01) == "first")
    }

    @Test func settingAgainReplacesRatherThanAccumulates() {
        var c = corrections()
        c.set("Levis", mediaRef: "m", startSeconds: 4.20)
        #expect(c.all.count == 1)
        #expect(c.text(mediaRef: "m", startSeconds: 4.20) == "Levis")
    }

    // Clearing reverts to what was actually recognised, rather than storing an empty word.
    @Test func emptyTextClearsTheCorrection() {
        var c = corrections()
        c.set("   ", mediaRef: "m", startSeconds: 4.20)
        #expect(c.isEmpty)
        #expect(c.text(mediaRef: "m", startSeconds: 4.20) == nil)
    }

    @Test func survivesAProjectRoundTrip() throws {
        let file = ProjectFile(
            timelines: [Fixtures.timeline()],
            activeTimelineId: nil, openTimelineIds: nil, viewStates: nil,
            speakers: nil, multicamGroups: nil,
            transcriptCorrections: corrections().all
        )
        let decoded = try ProjectFile.decode(try JSONEncoder().encode(file))
        let restored = TranscriptCorrections(decoded.transcriptCorrections ?? [])
        #expect(restored.text(mediaRef: "m", startSeconds: 4.20) == "Levi's")
    }

    // Projects written before corrections existed must still open.
    @Test func projectsWithoutCorrectionsDecode() throws {
        let json = #"{"timelines":[{"fps":30,"width":1920,"height":1080,"tracks":[]}]}"#
        let decoded = try ProjectFile.decode(Data(json.utf8))
        #expect(decoded.transcriptCorrections == nil)
        #expect(TranscriptCorrections(decoded.transcriptCorrections ?? []).isEmpty)
    }
}

@Suite("FillerWords")
struct FillerWordsTests {

    @Test func matchesDisfluenciesRegardlessOfCaseOrPunctuation() {
        #expect(FillerWords.isFiller("um"))
        #expect(FillerWords.isFiller("Um,"))
        #expect(FillerWords.isFiller(" UH. "))
        #expect(FillerWords.isFiller("Hmm…"))
    }

    // Words that are fillers only sometimes stay the user's call — a one-click pass must not
    // silently delete meaning.
    @Test func leavesAmbiguousWordsAlone() {
        for word in ["like", "so", "right", "well", "you", "know", "and"] {
            #expect(!FillerWords.isFiller(word), "\(word) must not be treated as a filler")
        }
    }

    @Test func reportsIndicesInTranscriptOrder() {
        let words = ["So", "um", "we", "uh", "shipped"].enumerated().map {
            TimelineWord(
                index: $0.offset, clipId: "c", trackIndex: 0, clipStartFrame: 0, clipEndFrame: 100,
                text: $0.element, startFrame: $0.offset * 10, endFrame: $0.offset * 10 + 9,
                startSeconds: Double($0.offset), endSeconds: Double($0.offset) + 0.3, speaker: nil
            )
        }
        #expect(FillerWords.indices(in: words) == [1, 3])
    }

    // remove_words matches and the panel's filler pass must agree on what a token is.
    @MainActor
    @Test func sharesOneNormalizationWithTheAgentPath() {
        #expect(ToolExecutor.normalizedWordMatch("Um,") == FillerWords.normalized("Um,"))
    }
}
