import Foundation

extension EditorViewModel {
    /// Rename a misrecognised word. Display only — the word keeps its timing, nothing is re-cut,
    /// and every reader of the transcript (panel, agent, captions) picks the fix up on its next read.
    ///
    /// Project state like the speaker registry, so it checkpoints rather than joining timeline undo.
    /// An empty text clears the correction, reverting the word to what was recognised.
    @discardableResult
    func correctWord(_ word: TimelineWord, to text: String) -> Bool {
        guard let clip = findClip(id: word.clipId).map({ timeline.tracks[$0.trackIndex].clips[$0.clipIndex] })
        else { return false }
        let before = transcriptCorrections
        transcriptCorrections.set(text, mediaRef: clip.mediaRef, startSeconds: word.startSeconds)
        guard transcriptCorrections != before else { return false }
        onProjectCheckpointRequired?()
        return true
    }
}
