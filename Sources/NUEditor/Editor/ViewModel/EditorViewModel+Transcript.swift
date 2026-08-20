import Foundation

extension EditorViewModel {
    /// The timeline's spoken words with project-frame positions, produced by the
    /// exact same on-device path `remove_words` uses — so the transcript UI and the
    /// agent share one word→frame mapping rather than a second implementation.
    ///
    /// On-device only; runs its transcription/analysis off the main actor.
    func loadTimelineTranscript() async throws -> TimelineTranscript {
        let executor = ToolExecutor(editor: self)
        let context = TranscriptionToolContext(provider: .local, preferredLocale: nil)
        return try await executor.timelineTranscript(self, context: context)
    }
}
