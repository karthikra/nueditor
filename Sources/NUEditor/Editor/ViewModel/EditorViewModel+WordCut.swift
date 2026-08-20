import Foundation

extension EditorViewModel {
    struct WordCutResult {
        let removedFrames: Int
        let removedTexts: [String]
    }

    enum WordCutOutcome {
        case ok(WordCutResult)
        /// The selection resolved to no removable frames.
        case empty
        /// The selection spans multiple unlinked tracks; the value lists them.
        case multiTrack(String)
        /// The ripple delete refused; the value is the reason (e.g. a sync-locked track).
        case refused(String)
    }

    /// Cut the selected transcript words and close the gaps — the shared engine behind
    /// both `remove_words` (agent) and the transcript panel's Delete. Produces one
    /// undoable action; linked A/V partners are cut on the same span by the ripple.
    ///
    /// `selected` holds `TimelineWord.index` values from a `TimelineTranscript`.
    func cutSelectedWords(
        in transcript: TimelineTranscript,
        selected: Set<Int>,
        aggressiveness: CutAggressiveness,
        undoName: String
    ) -> WordCutOutcome {
        let keepGapFrames = Int((aggressiveness.keptGapMs / 1000.0 * Double(timeline.fps)).rounded())
        let snapWindow = max(2, keepGapFrames * 2)
        var removedTexts: [String] = []
        var rangesByTrack: [Int: [FrameRange]] = [:]
        var involvedClips: [String] = []

        for group in transcript.groups() {
            let clipWords = group.words
            guard clipWords.contains(where: { selected.contains($0.index) }) else { continue }
            removedTexts.append(contentsOf: clipWords
                .filter { selected.contains($0.index) && $0.endFrame > $0.startFrame }
                .map(\.text))
            let plan = clipWords.map {
                WordCutPlanner.Word(startFrame: $0.startFrame, endFrame: $0.endFrame, selected: selected.contains($0.index))
            }
            let ranges = WordCutPlanner.cutRanges(
                words: plan, clipStart: group.clipStartFrame, clipEnd: group.clipEndFrame, keepGapFrames: keepGapFrames
            )
            guard !ranges.isEmpty else { continue }
            // Snap each cut boundary into the nearest VAD silence so the splice lands in a
            // breath gap — silence-to-silence removes the click and leftover word fragments.
            // No-op (falls back to the word-boundary cut) when analysis isn't ready.
            let clip = findClip(id: group.clipId).map { timeline.tracks[$0.trackIndex].clips[$0.clipIndex] }
            let snapped = ranges.map { r in
                clip.map { snapCutRangeToSilence(clip: $0, range: r, window: snapWindow) } ?? r
            }
            rangesByTrack[group.trackIndex, default: []].append(contentsOf: RippleEngine.mergeRanges(snapped))
            involvedClips.append(group.clipId)
        }
        guard !rangesByTrack.isEmpty else { return .empty }

        // Cut one track; the ripple carries its linked A/V partners across the same span.
        // Multiple tracks are only coherent as one linked unit (camera + mic); otherwise
        // cutting them together would break alignment.
        let primaryTrack: Int
        if rangesByTrack.count == 1 {
            primaryTrack = rangesByTrack.first!.key
        } else {
            let groupIds: [String] = involvedClips.compactMap { id in
                findClip(id: id).flatMap { timeline.tracks[$0.trackIndex].clips[$0.clipIndex].linkGroupId }
            }
            guard groupIds.count == involvedClips.count, Set(groupIds).count == 1 else {
                let tracks = rangesByTrack.keys.sorted().map(String.init).joined(separator: ", ")
                return .multiTrack(tracks)
            }
            primaryTrack = rangesByTrack.keys.min()!
        }
        // Only the primary track's own ranges — the ripple removes the same span from
        // linked partners, so flattening foreign-track frames would over-cut.
        let primaryRanges = rangesByTrack[primaryTrack]!

        let outcome = undo.perform(undoName) {
            rippleDeleteRangesOnTrack(trackIndex: primaryTrack, ranges: primaryRanges)
        }
        switch outcome {
        case .ok(let report):
            return .ok(WordCutResult(removedFrames: report.removedFrames, removedTexts: removedTexts))
        case .refused(let reason):
            return .refused(reason)
        }
    }

    /// Snap a cut range's boundaries into the nearest VAD silence within `window` frames,
    /// so the splice sits in a breath gap. Silence never contains speech, so this can't
    /// drop a kept word; when analysis isn't ready every boundary stays put.
    private func snapCutRangeToSilence(clip: Clip, range: FrameRange, window: Int) -> FrameRange {
        let s = snapBoundaryToSilence(clip: clip, frame: range.start, window: window)
        let e = snapBoundaryToSilence(clip: clip, frame: range.end, window: window)
        guard e > s else { return range }
        return FrameRange(start: s, end: e)
    }

    private func snapBoundaryToSilence(clip: Clip, frame: Int, window: Int) -> Int {
        if deadAirSpanRange(clip: clip, atTimelineFrame: frame) != nil { return frame }  // already quiet
        for d in 1...window {
            if let span = deadAirSpanRange(clip: clip, atTimelineFrame: frame - d) {
                return min(max(frame, span.start), span.end)   // nearest edge of the earlier silence
            }
            if let span = deadAirSpanRange(clip: clip, atTimelineFrame: frame + d) {
                return min(max(frame, span.start), span.end)   // nearest edge of the later silence
            }
        }
        return frame
    }

    /// Kick off (idempotent, cached) VAD + waveform analysis for the timeline's speech clips,
    /// so silence-snapping has data by the time the user cuts.
    func ensureSpeechAnalysisForTimeline() {
        let refs = Set(timeline.tracks.flatMap { $0.clips.map(\.mediaRef) })
        for asset in mediaAssets
        where refs.contains(asset.id) && (asset.type == .audio || (asset.type == .video && asset.hasAudio)) {
            mediaVisualCache.generateWaveform(for: asset)
        }
    }
}
