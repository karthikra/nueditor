import Foundation

extension ToolExecutor {

    private static let removeWordsAllowedKeys: Set<String> = ["words", "matches", "fillers", "cutAggressiveness", "jumpCut", "language"]

    func removeWords(_ editor: EditorViewModel, _ args: [String: Any]) async throws -> ToolResult {
        try validateUnknownKeys(args, allowed: Self.removeWordsAllowedKeys, path: "remove_words")
        let rawWords = args["words"] as? [Any]
        let rawMatches = args["matches"] as? [Any]
        let fillersOnly = args["fillers"] as? Bool ?? false
        if rawWords?.isEmpty == true || rawMatches?.isEmpty == true {
            throw ToolError("remove_words: words or matches must not be empty.")
        }
        guard rawWords != nil || rawMatches != nil || fillersOnly else {
            throw ToolError("Missing 'words', 'matches', or 'fillers'. Pass word indices from get_transcript, e.g. [5, [12, 18]], exact words like [\"um\", \"uh\"], or fillers: true for every disfluency.")
        }
        guard [rawWords != nil, rawMatches != nil, fillersOnly].filter({ $0 }).count == 1 else {
            throw ToolError("remove_words: pass exactly one of words, matches, or fillers.")
        }
        let aggressiveness: CutAggressiveness
        if let raw = args.string("cutAggressiveness") {
            guard let a = CutAggressiveness(rawValue: raw) else {
                throw ToolError("cutAggressiveness must be one of: \(CutAggressiveness.allCases.map(\.rawValue).joined(separator: ", ")).")
            }
            aggressiveness = a
        } else { aggressiveness = .balanced }
        let jumpCut: JumpCutStyle
        if let raw = args.string("jumpCut") {
            guard let style = JumpCutStyle(rawValue: raw) else {
                throw ToolError("jumpCut must be one of: \(JumpCutStyle.allCases.map(\.rawValue).joined(separator: ", ")).")
            }
            jumpCut = style
        } else { jumpCut = .hard }

        let context = try await transcriptionContext(args, path: "remove_words", preferLast: true) {
            await editor.captionCloudCreditCost(for: .init(autoDetect: true, provider: .cloud))
        }
        let transcript = try await timelineTranscript(editor, context: context)
        let allWords = transcript.words
        guard !allWords.isEmpty else { throw ToolError("No transcribable speech on the timeline.") }

        var selected = Set<Int>(), ignored: [Int] = []
        let maxIndex = allWords.count - 1
        if let rawWords {
            for (a, b) in try Self.parseWordSpans(rawWords) {
                let lo = min(a, b), hi = max(a, b)
                // Clamp to the valid transcript range so an out-of-range span can't iterate billions of times.
                if hi < 0 || lo > maxIndex { ignored.append(lo); continue }
                if lo < 0 { ignored.append(lo) }
                if hi > maxIndex { ignored.append(hi) }
                for idx in max(0, lo)...min(maxIndex, hi) { selected.insert(idx) }
            }
            guard !selected.isEmpty else {
                throw ToolError("None of the requested word indices are in range 0...\(maxIndex). Re-read get_transcript.")
            }
        } else if fillersOnly {
            selected = Set(FillerWords.indices(in: allWords))
            guard !selected.isEmpty else {
                throw ToolError("No filler words on the timeline — nothing to remove.")
            }
        } else if let rawMatches {
            let matches = try Self.parseWordMatches(rawMatches)
            for word in allWords where matches.contains(Self.normalizedWordMatch(word.text)) {
                selected.insert(word.index)
            }
            guard !selected.isEmpty else {
                throw ToolError("No transcript words matched: \(matches.sorted().joined(separator: ", ")). Re-read get_transcript or pass exact word indices.")
            }
        }

        let snapshot = timelineSnapshot(editor)
        let result: EditorViewModel.WordCutResult
        switch editor.cutSelectedWords(
            in: transcript, selected: selected, aggressiveness: aggressiveness,
            jumpCut: jumpCut, undoName: "Remove Words (Agent)"
        ) {
        case .ok(let r):
            result = r
        case .empty:
            throw ToolError("The selected words resolved to no removable frames. Re-read get_transcript.")
        case .multiTrack(let tracks):
            throw ToolError("Selected words span multiple unlinked tracks (\(tracks)). Remove words one track at a time — linked video/audio is cut automatically. If these tracks are the same source (e.g. camera + mic), link them into one unit first.")
        case .refused(let reason):
            throw ToolError("Ripple delete refused: \(reason)")
        }
        let removedTexts = result.removedTexts

        var extra: [String: Any] = [
            "removedWords": removedTexts.count, "removedFrames": result.removedFrames,
            "cutAggressiveness": aggressiveness.rawValue,
            "jumpCut": jumpCut.rawValue,
            "transcriptionSource": context.provider.rawValue,
        ]
        if jumpCut == .soft {
            // A boundary with no media past the out-point can't dissolve; say so rather than
            // reporting a soft cut that isn't there.
            extra["dissolvedJoins"] = editor.dissolvedJoinCount(atFrames: result.spliceFrames)
        }
        let preview = removedTexts.prefix(24).joined(separator: " ")
        if !preview.isEmpty { extra["removedText"] = removedTexts.count > 24 ? preview + " …" : preview }
        if !ignored.isEmpty { extra["indicesIgnored"] = ignored.sorted() }
        return mutationResult(
            editor, since: snapshot, extra: extra,
            notes: ["Word indices shifted — re-read get_transcript before another remove_words."]
        )
    }

    func removeSilence(_ editor: EditorViewModel, _ args: [String: Any]) throws -> ToolResult {
        try validateUnknownKeys(args, allowed: [], path: "remove_silence")
        let snapshot = timelineSnapshot(editor)
        let result = editor.undo.perform("Remove Silence (Agent)") {
            editor.removeAllDeadAir()
        }
        guard let result else {
            throw ToolError("No dead air on the timeline. Speech analysis may still be running, or the audio has no quiet non-speech sections.")
        }
        if let refusal = result.refusal, result.sections == 0 {
            throw ToolError("Ripple delete refused: \(refusal)")
        }
        var notes: [String] = []
        if let refusal = result.refusal {
            notes.append("A later track refused: \(refusal). Earlier tracks were already edited.")
        }
        return mutationResult(
            editor, since: snapshot,
            extra: ["sectionsRemoved": result.sections, "removedFrames": result.removedFrames],
            notes: notes
        )
    }

    static func parseWordSpans(_ raw: [Any]) throws -> [(Int, Int)] {
        try raw.enumerated().map { i, element in
            if let n = intFromAny(element) { return (n, n) }
            guard let pair = element as? [Any], pair.count == 2,
                  let a = intFromAny(pair[0]), let b = intFromAny(pair[1]) else {
                throw ToolError("words[\(i)]: expected an integer index or an [start, end] pair.")
            }
            return (a, b)
        }
    }

    static func parseWordMatches(_ raw: [Any]) throws -> Set<String> {
        let matches = try raw.enumerated().map { i, element in
            guard let text = element as? String else {
                throw ToolError("matches[\(i)]: expected a string.")
            }
            let normalized = normalizedWordMatch(text)
            guard !normalized.isEmpty else {
                throw ToolError("matches[\(i)]: expected a non-empty word.")
            }
            return normalized
        }
        return Set(matches)
    }

    static func normalizedWordMatch(_ text: String) -> String { FillerWords.normalized(text) }

    private static func intFromAny(_ v: Any) -> Int? {
        if let i = v as? Int { return i }
        if let n = v as? NSNumber { return n.intValue }
        if let d = v as? Double, d.rounded() == d { return safeInt(d) }
        return nil
    }
}
