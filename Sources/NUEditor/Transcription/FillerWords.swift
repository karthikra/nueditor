import Foundation

/// Disfluencies a one-click pass offers to remove.
///
/// Deliberately conservative: only tokens that carry no meaning in any sentence, so selecting
/// every filler never eats content. "like", "so", "right", and "you know" are fillers only
/// sometimes — the user selects those by hand.
enum FillerWords {
    static let english: Set<String> = [
        "um", "umm", "ummm", "uhm", "uh", "uhh", "uhhh",
        "er", "err", "erm", "ah", "ahh", "eh",
        "mm", "mmm", "hm", "hmm", "mhm", "huh",
    ]

    /// Comparison form for a transcript token: punctuation and case removed.
    static func normalized(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
            .lowercased()
    }

    static func isFiller(_ text: String) -> Bool {
        english.contains(normalized(text))
    }

    /// Indices of every filler in `words`, in transcript order.
    static func indices(in words: [TimelineWord]) -> [Int] {
        words.filter { isFiller($0.text) }.map(\.index)
    }
}
