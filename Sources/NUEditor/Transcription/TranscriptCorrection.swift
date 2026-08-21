import Foundation

/// A fix to a misrecognised word, kept with the project so it survives re-transcription and
/// reaches every reader of the transcript — the panel, the agent, and captions.
///
/// Keyed by the word's time in its *source* media, which no timeline edit can move. Display only:
/// it renames the word, it never re-aligns or re-cuts anything.
struct TranscriptCorrection: Codable, Sendable, Equatable {
    var mediaRef: String
    var startSeconds: Double
    var text: String
}

/// The project's corrections, looked up by source time with a small tolerance so a re-transcribe
/// that nudges a word by a few milliseconds still finds its fix.
struct TranscriptCorrections: Sendable, Equatable {
    /// Half the width of a typical short word — wide enough to survive re-timing, narrow enough
    /// that it can't land on a neighbour.
    static let toleranceSeconds = 0.08

    private var byMediaRef: [String: [TranscriptCorrection]] = [:]

    init(_ corrections: [TranscriptCorrection] = []) {
        for correction in corrections {
            byMediaRef[correction.mediaRef, default: []].append(correction)
        }
        for ref in byMediaRef.keys {
            byMediaRef[ref]?.sort { $0.startSeconds < $1.startSeconds }
        }
    }

    var isEmpty: Bool { byMediaRef.isEmpty }

    var all: [TranscriptCorrection] {
        byMediaRef.keys.sorted().flatMap { byMediaRef[$0] ?? [] }
    }

    /// The corrected text for the word at `seconds`, or nil when that word was never corrected.
    func text(mediaRef: String, startSeconds seconds: Double) -> String? {
        guard let candidates = byMediaRef[mediaRef] else { return nil }
        return candidates
            .filter { abs($0.startSeconds - seconds) <= Self.toleranceSeconds }
            .min { abs($0.startSeconds - seconds) < abs($1.startSeconds - seconds) }?
            .text
    }

    /// Records a correction, replacing any existing one for the same word. An empty text clears it,
    /// reverting the word to what was actually recognised.
    mutating func set(_ text: String, mediaRef: String, startSeconds seconds: Double) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        remove(mediaRef: mediaRef, startSeconds: seconds)
        guard !trimmed.isEmpty else { return }
        byMediaRef[mediaRef, default: []].append(
            TranscriptCorrection(mediaRef: mediaRef, startSeconds: seconds, text: trimmed)
        )
        byMediaRef[mediaRef]?.sort { $0.startSeconds < $1.startSeconds }
    }

    mutating func remove(mediaRef: String, startSeconds seconds: Double) {
        guard var candidates = byMediaRef[mediaRef] else { return }
        candidates.removeAll { abs($0.startSeconds - seconds) <= Self.toleranceSeconds }
        byMediaRef[mediaRef] = candidates.isEmpty ? nil : candidates
    }
}
