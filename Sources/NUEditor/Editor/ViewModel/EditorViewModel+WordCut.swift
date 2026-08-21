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
        let fps = timeline.fps
        let keepGapFrames = Int((aggressiveness.keptGapMs / 1000.0 * Double(fps)).rounded())
        var removedTexts: [String] = []
        var rangesByTrack: [Int: [FrameRange]] = [:]
        var involvedClips: [String] = []
        // Sub-frame silence to install once the ripple has split the clips, keyed by the cut
        // boundary (timeline frame) so it can be matched to the post-ripple fragment there.
        var leadInByTrackRangeEnd: [Int: [Int: EdgeSilencePlan]] = [:]
        var leadOutByTrackRangeStart: [Int: [Int: EdgeSilencePlan]] = [:]

        for group in transcript.groups() {
            let clipWords = group.words
            guard clipWords.contains(where: { selected.contains($0.index) }) else { continue }
            removedTexts.append(contentsOf: clipWords
                .filter { selected.contains($0.index) && $0.endFrame > $0.startFrame }
                .map(\.text))
            let plan = clipWords.map {
                WordCutPlanner.Word(startFrame: $0.startFrame, endFrame: $0.endFrame, selected: selected.contains($0.index))
            }
            // Precompute this clip's VAD silence spans (timeline frames) as plain data, then let
            // WordCutPlanner walk each cut boundary out to silence. Empty when analysis isn't ready
            // yet → the planner keeps its fixed margin.
            let clip = findClip(id: group.clipId).map { timeline.tracks[$0.trackIndex].clips[$0.clipIndex] }
            let silence = clip.map { deadAirRanges(for: $0) } ?? []
            let isSilent: ((Int) -> Bool)? = silence.isEmpty ? nil : { f in
                silence.contains { $0.start <= f && f < $0.end }
            }
            let ranges = WordCutPlanner.cutRanges(
                words: plan, clipStart: group.clipStartFrame, clipEnd: group.clipEndFrame,
                keepGapFrames: keepGapFrames, isSilent: isSilent
            )
            guard !ranges.isEmpty else { continue }
            rangesByTrack[group.trackIndex, default: []].append(contentsOf: ranges)
            involvedClips.append(group.clipId)

            // A frame cut removes whole frames; a removed word ending mid-frame leaves a fragment at
            // the splice that a frame-quantized fade can't touch. Measure it from the raw word times.
            if let clip {
                for r in ranges {
                    let removed = clipWords.filter {
                        selected.contains($0.index) && $0.endFrame > $0.startFrame
                            && $0.startFrame < r.end && $0.endFrame > r.start
                    }
                    guard let removedStart = removed.map(\.startSeconds).min(),
                          let removedEnd = removed.map(\.endSeconds).max() else { continue }
                    let sil = WordCutPlanner.edgeSilence(
                        removedStartSeconds: removedStart,
                        removedEndSeconds: removedEnd,
                        leftEdgeSourceSeconds: CaptionTranscriptMapper.sourceSeconds(ofTimelineFrame: r.start, clip: clip, fps: fps),
                        rightEdgeSourceSeconds: CaptionTranscriptMapper.sourceSeconds(ofTimelineFrame: r.end, clip: clip, fps: fps)
                    )
                    if sil.leadIn > 0 {
                        leadInByTrackRangeEnd[group.trackIndex, default: [:]][r.end] = EdgeSilencePlan(seconds: sil.leadIn, mediaRef: clip.mediaRef)
                    }
                    if sil.leadOut > 0 {
                        leadOutByTrackRangeStart[group.trackIndex, default: [:]][r.start] = EdgeSilencePlan(seconds: sil.leadOut, mediaRef: clip.mediaRef)
                    }
                }
            }
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
        let leadInEnds = leadInByTrackRangeEnd[primaryTrack] ?? [:]
        let leadOutStarts = leadOutByTrackRangeStart[primaryTrack] ?? [:]

        // Ripple and the sub-frame silence are one user intent → one undo group.
        let outcome = undo.perform(undoName) { () -> RippleRangesOutcome in
            let res = rippleDeleteRangesOnTrack(trackIndex: primaryTrack, ranges: primaryRanges)
            if case .ok(let report) = res, !(leadInEnds.isEmpty && leadOutStarts.isEmpty) {
                applyEdgeSilence(
                    report: report, primaryRanges: primaryRanges,
                    leadInByRangeEnd: leadInEnds, leadOutByRangeStart: leadOutStarts
                )
            }
            return res
        }
        switch outcome {
        case .ok(let report):
            return .ok(WordCutResult(removedFrames: report.removedFrames, removedTexts: removedTexts))
        case .refused(let reason):
            return .refused(reason)
        }
    }

    private struct EdgeSilencePlan {
        let seconds: Double
        let mediaRef: String
    }

    /// After the ripple splits the clips, mute the sub-frame fragment of a removed word that
    /// survives at each splice. The splice's post-ripple frame is the pre-cut range start minus
    /// everything removed before it; the fragment there shares the cut clip's `mediaRef`.
    private func applyEdgeSilence(
        report: RippleRangesReport,
        primaryRanges: [FrameRange],
        leadInByRangeEnd: [Int: EdgeSilencePlan],
        leadOutByRangeStart: [Int: EdgeSilencePlan]
    ) {
        let ti = report.anchorTrackIndex
        guard timeline.tracks.indices.contains(ti) else { return }
        let frags = report.resultingFragments
        func mediaRef(_ clipId: String) -> String? {
            findClip(id: clipId).map { timeline.tracks[$0.trackIndex].clips[$0.clipIndex].mediaRef }
        }
        var leadInByClip: [String: Double] = [:]
        var leadOutByClip: [String: Double] = [:]
        var removedBefore = 0
        for r in RippleEngine.mergeRanges(primaryRanges) {
            let splice = r.start - removedBefore
            removedBefore += r.length
            if let plan = leadInByRangeEnd[r.end],
               let right = frags.first(where: { $0.startFrame == splice && mediaRef($0.clipId) == plan.mediaRef }) {
                leadInByClip[right.clipId] = max(leadInByClip[right.clipId] ?? 0, plan.seconds)
            }
            if let plan = leadOutByRangeStart[r.start],
               let left = frags.first(where: { $0.startFrame + $0.durationFrames == splice && mediaRef($0.clipId) == plan.mediaRef }) {
                leadOutByClip[left.clipId] = max(leadOutByClip[left.clipId] ?? 0, plan.seconds)
            }
        }
        guard !leadInByClip.isEmpty || !leadOutByClip.isEmpty else { return }
        withTimelineSwap(actionName: "Trim Cut Audio") {
            for ci in timeline.tracks[ti].clips.indices {
                let id = timeline.tracks[ti].clips[ci].id
                if let s = leadInByClip[id] { timeline.tracks[ti].clips[ci].audioLeadInSeconds = s }
                if let s = leadOutByClip[id] { timeline.tracks[ti].clips[ci].audioLeadOutSeconds = s }
            }
        }
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
