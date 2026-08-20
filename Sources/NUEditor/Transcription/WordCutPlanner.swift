import Foundation

enum CutAggressiveness: String, Sendable, CaseIterable {
    case tight, balanced, loose
    var keptGapMs: Double { switch self { case .tight: 60; case .balanced: 150; case .loose: 320 } }
}

enum WordCutPlanner {
    struct Word: Equatable {
        let startFrame: Int, endFrame: Int, selected: Bool
    }

    /// Frame ranges to remove for the selected words, gaps merged.
    ///
    /// `isSilent`, when provided (VAD), replaces the fixed keep-gap margin: each boundary
    /// walks *outward through the removed word's own audio* to the surrounding silence,
    /// bounded by the neighbouring kept words. This catches a mis-timed word tail/onset
    /// (so the whole word is removed) and lands the splice in a breath gap, while never
    /// crossing into a kept word. Without `isSilent` it keeps the balanced margin as before.
    static func cutRanges(
        words: [Word],
        clipStart: Int,
        clipEnd: Int,
        keepGapFrames: Int,
        isSilent: ((Int) -> Bool)? = nil
    ) -> [FrameRange] {
        let words = words.filter { $0.endFrame > $0.startFrame }
        guard clipEnd > clipStart, !words.isEmpty else { return [] }
        let half = max(0, keepGapFrames / 2)
        var ranges: [FrameRange] = []
        var k = 0
        while k < words.count {
            guard words[k].selected else { k += 1; continue }
            var l = k
            while l + 1 < words.count, words[l + 1].selected { l += 1 }
            let left = k > 0 ? words[k - 1].endFrame : clipStart
            let right = l + 1 < words.count ? words[l + 1].startFrame : clipEnd
            let runStart = words[k].startFrame, runEnd = words[l].endFrame
            let start: Int, end: Int
            if let isSilent {
                var s = min(runStart, right)
                while s > left, !isSilent(s - 1) { s -= 1 }   // back through a mis-timed onset to silence
                var e = max(runEnd, left)
                while e < right, !isSilent(e) { e += 1 }       // forward through a mis-timed tail to silence
                start = max(clipStart, s)
                end = min(clipEnd, e)
            } else {
                let keepBefore = min(max(0, runStart - left), half)
                let keepAfter = min(max(0, right - runEnd), half)
                start = max(clipStart, min(left + keepBefore, runStart))
                end = min(clipEnd, max(runEnd, right - keepAfter))
            }
            if end > start { ranges.append(FrameRange(start: start, end: end)) }
            k = l + 1
        }
        return RippleEngine.mergeRanges(ranges)
    }
}
