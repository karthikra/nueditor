import AppKit
import SwiftUI

/// Text-based editing: the timeline's speech as prose. Click a word to seek; click to
/// select and shift-click to extend a range, then Delete to cut the audio (and linked
/// video) for those words and close the gap. The current word highlights during playback.
///
/// Words and the cut both come from the same on-device path `remove_words` uses
/// (`loadTimelineTranscript` → `cutSelectedWords`), so the UI and the agent share one
/// word→frame mapping and one cut engine.
struct TranscriptTab: View {
    @Environment(EditorViewModel.self) private var editor

    @State private var transcript: TimelineTranscript?
    @State private var phase: Phase = .idle
    @State private var reloadTick = 0

    @State private var selection: Set<Int> = []
    @State private var anchor: Int?
    @State private var note: String?

    private enum Phase: Equatable { case idle, loading, loaded, empty, failed(String) }

    private var words: [TimelineWord] { transcript?.words ?? [] }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().overlay(AppTheme.Border.subtleColor)
            content
            if !selection.isEmpty { selectionBar }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .task(id: reloadTick) { await load() }
        .onKeyPress(.delete) { deleteSelection() ? .handled : .ignored }
        .onKeyPress(.deleteForward) { deleteSelection() ? .handled : .ignored }
        .onKeyPress(.escape) { clearSelection() ? .handled : .ignored }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: AppTheme.Spacing.sm) {
            Text("Transcript")
                .font(.system(size: AppTheme.FontSize.md, weight: AppTheme.FontWeight.medium))
                .foregroundStyle(AppTheme.Text.primaryColor)
            Spacer(minLength: 0)
            Button { reloadTick += 1 } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: AppTheme.FontSize.sm, weight: AppTheme.FontWeight.medium))
                    .foregroundStyle(AppTheme.Text.tertiaryColor)
            }
            .buttonStyle(.plain)
            .disabled(phase == .loading)
            .help("Re-read the transcript from the current timeline")
        }
        .padding(.horizontal, AppTheme.Spacing.lg)
        .padding(.vertical, AppTheme.Spacing.md)
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        switch phase {
        case .idle, .loading:
            centered {
                ProgressView().controlSize(.small)
                Text("Transcribing…")
                    .font(.system(size: AppTheme.FontSize.sm))
                    .foregroundStyle(AppTheme.Text.tertiaryColor)
            }
        case .empty:
            centered {
                Text("No speech on the timeline.")
                    .font(.system(size: AppTheme.FontSize.sm))
                    .foregroundStyle(AppTheme.Text.tertiaryColor)
            }
        case .failed(let message):
            centered {
                Text(message)
                    .font(.system(size: AppTheme.FontSize.sm))
                    .foregroundStyle(AppTheme.Status.errorColor)
                    .multilineTextAlignment(.center)
                Button("Try again") { reloadTick += 1 }
                    .buttonStyle(.plain)
                    .font(.system(size: AppTheme.FontSize.sm, weight: AppTheme.FontWeight.medium))
                    .foregroundStyle(AppTheme.Accent.primary)
            }
        case .loaded:
            transcriptBody
        }
    }

    private var transcriptBody: some View {
        // `currentIndex` is read only while playing, so a stopped playhead doesn't
        // invalidate this view on every scrub of an unrelated control.
        let currentIndex = editor.isPlaying ? currentWordIndex : nil
        return ScrollViewReader { proxy in
            ScrollView {
                FlowLayout(spacing: AppTheme.Spacing.xs, lineSpacing: AppTheme.Spacing.xs) {
                    ForEach(words.indices, id: \.self) { i in
                        WordChip(
                            text: words[i].text,
                            isSelected: selection.contains(i),
                            isCurrent: i == currentIndex
                        ) { handleTap(i) }
                        .id(i)
                    }
                }
                .padding(AppTheme.Spacing.lg)
            }
            .onChange(of: currentIndex) { _, new in
                guard let new else { return }
                withAnimation(.easeOut(duration: AppTheme.Anim.transition)) {
                    proxy.scrollTo(new, anchor: .center)
                }
            }
        }
    }

    // MARK: - Selection bar

    private var selectionBar: some View {
        HStack(spacing: AppTheme.Spacing.sm) {
            Text(selection.count == 1 ? "1 word" : "\(selection.count) words")
                .font(.system(size: AppTheme.FontSize.sm, weight: AppTheme.FontWeight.medium))
                .foregroundStyle(AppTheme.Text.secondaryColor)
            if let note {
                Text(note)
                    .font(.system(size: AppTheme.FontSize.xs))
                    .foregroundStyle(AppTheme.Status.warningColor)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            Button("Clear") { _ = clearSelection() }
                .buttonStyle(.plain)
                .font(.system(size: AppTheme.FontSize.sm))
                .foregroundStyle(AppTheme.Text.tertiaryColor)
            Button { _ = deleteSelection() } label: {
                Label("Delete", systemImage: "scissors")
                    .font(.system(size: AppTheme.FontSize.sm, weight: AppTheme.FontWeight.medium))
            }
            .buttonStyle(.editorPrimary)
            .help("Cut the selected words from the audio (and linked video)")
        }
        .padding(.horizontal, AppTheme.Spacing.lg)
        .padding(.vertical, AppTheme.Spacing.md)
        .background(AppTheme.Background.raisedColor)
        .overlay(alignment: .top) {
            Rectangle().fill(AppTheme.Border.primaryColor).frame(height: AppTheme.BorderWidth.hairline)
        }
    }

    // MARK: - Interaction

    private func handleTap(_ i: Int) {
        note = nil
        if NSEvent.modifierFlags.contains(.shift), let a = anchor {
            selection = Set(min(a, i)...max(a, i))
        } else {
            selection = [i]
            anchor = i
        }
        editor.seekToFrame(words[i].startFrame, mode: .exact)
    }

    @discardableResult
    private func clearSelection() -> Bool {
        guard !selection.isEmpty else { return false }
        selection = []
        anchor = nil
        note = nil
        return true
    }

    /// Returns true if it consumed a delete (there was a selection to act on).
    @discardableResult
    private func deleteSelection() -> Bool {
        guard let transcript, !selection.isEmpty else { return false }
        switch editor.cutSelectedWords(in: transcript, selected: selection, aggressiveness: .balanced, undoName: "Delete Words") {
        case .ok:
            selection = []
            anchor = nil
            note = nil
            reloadTick += 1   // frames shifted — re-read the transcript
        case .empty:
            note = "Nothing removable in the selection."
        case .multiTrack(let tracks):
            note = "Selection spans unlinked tracks (\(tracks))."
        case .refused(let reason):
            note = reason
        }
        return true
    }

    // MARK: - Loading

    private func load() async {
        phase = .loading
        selection = []
        anchor = nil
        do {
            let t = try await editor.loadTimelineTranscript()
            transcript = t
            phase = t.words.isEmpty ? .empty : .loaded
        } catch {
            phase = .failed(Log.detail(error))
        }
    }

    /// The word whose [startFrame, endFrame) spans the playhead, else nil.
    private var currentWordIndex: Int? {
        let f = editor.currentFrame
        return words.firstIndex { f >= $0.startFrame && f < $0.endFrame }
    }

    @ViewBuilder
    private func centered<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(spacing: AppTheme.Spacing.sm) { content() }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(AppTheme.Spacing.lg)
    }
}

// MARK: - Word chip

private struct WordChip: View {
    let text: String
    let isSelected: Bool
    let isCurrent: Bool
    let onTap: () -> Void

    @State private var hovering = false

    var body: some View {
        Text(text)
            .font(.system(size: AppTheme.FontSize.smMd))
            .foregroundStyle(foreground)
            .padding(.horizontal, AppTheme.Spacing.xxs)
            .padding(.vertical, AppTheme.Spacing.xxs)
            .background(
                RoundedRectangle(cornerRadius: AppTheme.Radius.xs, style: .continuous)
                    .fill(background)
            )
            .contentShape(RoundedRectangle(cornerRadius: AppTheme.Radius.xs))
            .onTapGesture(perform: onTap)
            .onHover { hovering = $0 }
    }

    private var foreground: Color {
        isSelected || isCurrent ? AppTheme.Text.primaryColor : AppTheme.Text.secondaryColor
    }

    private var background: Color {
        if isSelected { return AppTheme.Accent.primary.opacity(AppTheme.Opacity.strong) }
        if isCurrent { return AppTheme.Accent.primary.opacity(AppTheme.Opacity.medium) }
        if hovering { return AppTheme.Text.primaryColor.opacity(AppTheme.Opacity.faint) }
        return .clear
    }
}

// MARK: - Flow layout (prose wrapping)

private struct FlowLayout: SwiftUI.Layout {
    var spacing: CGFloat = 4
    var lineSpacing: CGFloat = 4

    func sizeThatFits(proposal: ProposedViewSize, subviews: LayoutSubviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, lineHeight: CGFloat = 0
        for sv in subviews {
            let s = sv.sizeThatFits(.unspecified)
            if x + s.width > maxWidth, x > 0 {
                x = 0; y += lineHeight + lineSpacing; lineHeight = 0
            }
            x += s.width + spacing
            lineHeight = max(lineHeight, s.height)
        }
        let width = maxWidth == .infinity ? x : maxWidth
        return CGSize(width: width, height: y + lineHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: LayoutSubviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, lineHeight: CGFloat = 0
        for sv in subviews {
            let s = sv.sizeThatFits(.unspecified)
            if x + s.width > bounds.maxX, x > bounds.minX {
                x = bounds.minX; y += lineHeight + lineSpacing; lineHeight = 0
            }
            sv.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(s))
            x += s.width + spacing
            lineHeight = max(lineHeight, s.height)
        }
    }
}
