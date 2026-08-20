import SwiftUI

/// Read-only transcript of the timeline's speech, rendered as prose. Click a word to
/// seek there; the current word highlights during playback. Words carry project-frame
/// positions from the same path `remove_words` uses (see `loadTimelineTranscript`).
struct TranscriptTab: View {
    @Environment(EditorViewModel.self) private var editor

    @State private var words: [TimelineWord] = []
    @State private var phase: Phase = .idle
    @State private var reloadTick = 0

    private enum Phase: Equatable {
        case idle, loading, loaded, empty, failed(String)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().overlay(AppTheme.Border.subtleColor)
            content
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .task(id: reloadTick) { await load() }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: AppTheme.Spacing.sm) {
            Text("Transcript")
                .font(.system(size: AppTheme.FontSize.md, weight: AppTheme.FontWeight.medium))
                .foregroundStyle(AppTheme.Text.primaryColor)
            Spacer(minLength: 0)
            Button {
                reloadTick += 1
            } label: {
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
                        WordChip(text: words[i].text, isCurrent: i == currentIndex) {
                            editor.seekToFrame(words[i].startFrame, mode: .exact)
                        }
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

    // MARK: - Loading

    private func load() async {
        phase = .loading
        do {
            let transcript = try await editor.loadTimelineTranscript()
            words = transcript.words
            phase = words.isEmpty ? .empty : .loaded
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
    let isCurrent: Bool
    let onTap: () -> Void

    @State private var hovering = false

    var body: some View {
        Text(text)
            .font(.system(size: AppTheme.FontSize.smMd))
            .foregroundStyle(isCurrent ? AppTheme.Text.primaryColor : AppTheme.Text.secondaryColor)
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

    private var background: Color {
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
