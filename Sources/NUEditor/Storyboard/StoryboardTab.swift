import SwiftUI

/// The storyboard: each beat of the script with the footage NUEDIT matched to it, and the gaps.
///
/// NUEDIT scores coverage and keeps every correction; this renders its board, pulls card frames
/// from footage on this Mac, and sends the editor's corrections back.
struct StoryboardTab: View {
    @Environment(EditorViewModel.self) private var editor

    private var model: StoryboardModel { editor.storyboard }

    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.zero) {
            header
            Divider().overlay(AppTheme.Border.subtleColor)
            if model.isLinked, let board = model.board { summaryBar(board) }
            if let message = model.message { messageBar(message) }
            content
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .onAppear { if model.status == .idle { model.reload() } }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: AppTheme.Spacing.sm) {
            Text("Storyboard")
                .font(.system(size: AppTheme.FontSize.md, weight: AppTheme.FontWeight.medium))
                .foregroundStyle(AppTheme.Text.primaryColor)
            if model.scripts.count > 1, let selected = model.selectedScriptId {
                Picker("", selection: Binding(get: { selected }, set: { model.select(scriptId: $0) })) {
                    ForEach(model.scripts) { Text($0.title).tag($0.id) }
                }
                .labelsHidden()
                .fixedSize()
            }
            Spacer(minLength: 0)
            Button { editor.showScriptImport = true } label: { headerIcon("square.and.arrow.down") }
                .buttonStyle(.plain)
                .disabled(!model.isLinked)
                .help("Import a script from Google Sheets, Docs, or a file")
            Button { model.reload() } label: { headerIcon("arrow.clockwise") }
                .buttonStyle(.plain)
                .disabled(model.status == .loading || !model.isLinked)
                .help("Reload the board from NUEDIT")
        }
        .padding(.horizontal, AppTheme.Spacing.lg)
        .padding(.vertical, AppTheme.Spacing.md)
    }

    private func headerIcon(_ name: String) -> some View {
        Image(systemName: name)
            .font(.system(size: AppTheme.FontSize.sm, weight: AppTheme.FontWeight.medium))
            .foregroundStyle(AppTheme.Text.tertiaryColor)
    }

    // MARK: - Summary and jobs

    private func summaryBar(_ board: StoryboardModel.Board) -> some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.xs) {
            HStack(spacing: AppTheme.Spacing.md) {
                countChip(board.counts.covered, "covered", .covered)
                countChip(board.counts.weak, "weak", .weak)
                countChip(board.counts.missing, "missing", .missing)
                countChip(board.counts.scriptGap, "script gap\(board.counts.scriptGap == 1 ? "" : "s")", .scriptGap)
                Spacer(minLength: 0)
            }
            jobRow(board)
        }
        .padding(.horizontal, AppTheme.Spacing.lg)
        .padding(.vertical, AppTheme.Spacing.sm)
    }

    @ViewBuilder
    private func jobRow(_ board: StoryboardModel.Board) -> some View {
        switch model.job {
        case .matching:
            progressLine("Matching footage to beats…")
        case .recaptioning(let done, let total):
            progressLine(total > 0 ? "Describing footage… \(done) of \(total)" : "Describing footage…")
        case .none:
            HStack(spacing: AppTheme.Spacing.md) {
                switch board.matching {
                case .notRun: caption("Footage hasn't been matched to this script yet.")
                case .stale: caption("Matching predates a scoring change.")
                case .done: EmptyView()
                }
                Spacer(minLength: 0)
                Button(board.matching == .done ? "Re-match" : "Run Matching") { model.runMatching() }
                    .buttonStyle(.link)
                    .help("Match every beat to the project's described footage")
                Button("Describe Footage") { model.recaption() }
                    .buttonStyle(.link)
                    .help("Describe footage NUEDIT hasn't captioned yet, so matching can find it")
            }
            .font(.system(size: AppTheme.FontSize.xs))
        }
    }

    private func countChip(_ count: Int, _ label: String, _ coverage: NUEDITBackendClient.Board.Coverage) -> some View {
        HStack(spacing: AppTheme.Spacing.xs) {
            Circle().fill(Self.color(coverage)).frame(width: AppTheme.IconSize.xs / 2, height: AppTheme.IconSize.xs / 2)
            Text("\(count) \(label)")
        }
        .font(.system(size: AppTheme.FontSize.xs, weight: AppTheme.FontWeight.medium))
        .foregroundStyle(AppTheme.Text.secondaryColor)
    }

    private func progressLine(_ text: String) -> some View {
        HStack(spacing: AppTheme.Spacing.sm) {
            ProgressView().controlSize(.mini)
            caption(text)
        }
    }

    private func messageBar(_ message: String) -> some View {
        Text(message)
            .font(.system(size: AppTheme.FontSize.xs))
            .foregroundStyle(AppTheme.Status.warningColor)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, AppTheme.Spacing.lg)
            .padding(.bottom, AppTheme.Spacing.sm)
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        if !model.isLinked {
            emptyState("This project isn't linked to a NUEDIT project, so there's no storyboard yet.",
                       detail: "NUEDIT links a project with the tower_link tool.")
        } else {
            switch model.status {
            case .idle, .loading where model.board == nil:
                VStack { ProgressView().controlSize(.small) }.frame(maxWidth: .infinity).padding(AppTheme.Spacing.xl)
            case .failed(let reason):
                emptyState(reason, detail: nil, retry: true)
            default:
                if model.scripts.isEmpty {
                    emptyState("No script yet.", detail: "Import an AV script from Google Sheets, Docs, or a CSV to build the storyboard.",
                               action: ("Import Script…", { editor.showScriptImport = true }))
                } else if let board = model.board {
                    boardList(board)
                }
            }
        }
    }

    private func boardList(_ board: StoryboardModel.Board) -> some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: AppTheme.Spacing.md) {
                ForEach(board.beats) { beat in
                    BeatCard(beat: beat, board: board, model: model)
                }
                if !board.unusedFootage.isEmpty {
                    UnusedFootageSection(board: board, model: model)
                }
            }
            .padding(AppTheme.Spacing.lg)
        }
    }

    private func emptyState(
        _ message: String, detail: String?, retry: Bool = false, action: (String, () -> Void)? = nil
    ) -> some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.sm) {
            Text(message)
                .font(.system(size: AppTheme.FontSize.sm))
                .foregroundStyle(AppTheme.Text.secondaryColor)
                .fixedSize(horizontal: false, vertical: true)
            if let detail { caption(detail) }
            if retry { Button("Try Again") { model.reload() }.buttonStyle(.link) }
            if let action { Button(action.0, action: action.1).buttonStyle(.link) }
        }
        .padding(AppTheme.Spacing.lg)
    }

    private func caption(_ text: String) -> some View {
        Text(text)
            .font(.system(size: AppTheme.FontSize.xs))
            .foregroundStyle(AppTheme.Text.tertiaryColor)
            .fixedSize(horizontal: false, vertical: true)
    }

    static func color(_ coverage: NUEDITBackendClient.Board.Coverage) -> Color {
        switch coverage {
        case .covered: AppTheme.Status.successColor
        case .weak: AppTheme.Status.warningColor
        case .missing: AppTheme.Status.errorColor
        case .scriptGap: AppTheme.Text.tertiaryColor
        }
    }

    static func coverageName(_ coverage: NUEDITBackendClient.Board.Coverage) -> String {
        switch coverage {
        case .covered: "Covered"
        case .weak: "Weak match"
        case .missing: "Missing"
        case .scriptGap: "Script gap"
        }
    }

    static func timing(_ seconds: Double) -> String {
        seconds < 60 ? String(format: "%.1fs", seconds) : String(format: "%d:%04.1f", Int(seconds) / 60, seconds.truncatingRemainder(dividingBy: 60))
    }
}

// MARK: - Beat card

private struct BeatCard: View {
    @Environment(EditorViewModel.self) private var editor
    let beat: NUEDITBackendClient.Board.Beat
    let board: NUEDITBackendClient.Board
    let model: StoryboardModel
    @State private var showsMatches = false

    private var rejected: [NUEDITBackendClient.Board.Override] {
        board.overrides.filter { $0.beatId == beat.sectionId && $0.action == "reject" }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.sm) {
            StoryboardFrame(footageId: beat.matches.first?.footageId, frameMs: beat.matches.first?.frameMs,
                            coverage: beat.coverage)
                .frame(height: AppTheme.Storyboard.cardFrameHeight)
            HStack(alignment: .firstTextBaseline, spacing: AppTheme.Spacing.sm) {
                Text(beat.label?.isEmpty == false ? beat.label! : "\(beat.order)")
                    .font(.system(size: AppTheme.FontSize.sm, weight: AppTheme.FontWeight.semibold))
                    .foregroundStyle(AppTheme.Text.primaryColor)
                if let scene = beat.scene, !scene.isEmpty {
                    Text(scene).lineLimit(1).foregroundStyle(AppTheme.Text.tertiaryColor)
                }
                Spacer(minLength: 0)
                Text(StoryboardTab.coverageName(beat.coverage))
                    .foregroundStyle(StoryboardTab.color(beat.coverage))
                if let duration = beat.durationSeconds {
                    Text(StoryboardTab.timing(duration)).foregroundStyle(AppTheme.Text.tertiaryColor)
                }
            }
            .font(.system(size: AppTheme.FontSize.xs))
            text(beat.visual, empty: "No visual description — ask the writer what we see.", color: AppTheme.Text.primaryColor)
            if let audio = beat.audio, !audio.isEmpty { text(audio, color: AppTheme.Text.secondaryColor) }
            if let ost = beat.onScreenText, !ost.isEmpty { text("Super: \(ost)", color: AppTheme.Text.tertiaryColor) }
            if !beat.matches.isEmpty || !rejected.isEmpty { matchesDisclosure }
        }
        .padding(AppTheme.Spacing.md)
        .background(AppTheme.Background.raisedColor, in: RoundedRectangle(cornerRadius: AppTheme.Radius.md))
    }

    private func text(_ value: String?, empty: String? = nil, color: Color) -> some View {
        let shown = (value?.isEmpty == false) ? value! : (empty ?? "")
        return Text(shown)
            .font(.system(size: AppTheme.FontSize.sm))
            .foregroundStyle(value?.isEmpty == false ? color : AppTheme.Status.warningColor)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var matchesDisclosure: some View {
        DisclosureGroup(isExpanded: $showsMatches) {
            VStack(alignment: .leading, spacing: AppTheme.Spacing.xs) {
                ForEach(Array(beat.matches.enumerated()), id: \.offset) { _, match in matchRow(match) }
                ForEach(rejected, id: \.overrideId) { override in
                    HStack {
                        Text("Rejected \(editor.asset(forFootageId: override.footageId)?.name ?? "footage")")
                            .foregroundStyle(AppTheme.Text.tertiaryColor)
                        Spacer(minLength: 0)
                        Button("Undo") { model.undoOverride(override.overrideId) }.buttonStyle(.link)
                    }
                    .font(.system(size: AppTheme.FontSize.xs))
                }
            }
            .padding(.top, AppTheme.Spacing.xs)
        } label: {
            Text("\(beat.matches.count) match\(beat.matches.count == 1 ? "" : "es")")
                .font(.system(size: AppTheme.FontSize.xs, weight: AppTheme.FontWeight.medium))
                .foregroundStyle(AppTheme.Text.secondaryColor)
        }
    }

    private func matchRow(_ match: NUEDITBackendClient.Board.Match) -> some View {
        let asset = editor.asset(forFootageId: match.footageId)
        return HStack(spacing: AppTheme.Spacing.sm) {
            StoryboardFrame(footageId: match.footageId, frameMs: match.frameMs, coverage: nil)
                .frame(width: AppTheme.Storyboard.matchThumbWidth, height: AppTheme.Storyboard.matchThumbHeight)
            VStack(alignment: .leading, spacing: AppTheme.Spacing.xxs) {
                Text(asset?.name ?? "Not in this project").lineLimit(1).foregroundStyle(AppTheme.Text.primaryColor)
                Text(matchDetail(match)).foregroundStyle(AppTheme.Text.tertiaryColor)
            }
            Spacer(minLength: 0)
            if let asset {
                Button("Preview") { preview(asset, atMs: match.startMs) }.buttonStyle(.link)
            }
            if match.source == .override, let overrideId = match.overrideId {
                Button("Undo") { model.undoOverride(overrideId) }.buttonStyle(.link)
            } else {
                Button("Reject") { model.reject(match.footageId, startMs: match.startMs, endMs: match.endMs, for: beat.sectionId) }
                    .buttonStyle(.link)
            }
        }
        .font(.system(size: AppTheme.FontSize.xs))
    }

    private func matchDetail(_ match: NUEDITBackendClient.Board.Match) -> String {
        let range = "\(StoryboardTab.timing(Double(match.startMs) / 1000))–\(StoryboardTab.timing(Double(match.endMs) / 1000))"
        if match.source == .override { return "\(range) · assigned by you" }
        return match.confidence.map { "\(range) · \(Int(($0 * 100).rounded()))%" } ?? range
    }

    private func preview(_ asset: MediaAsset, atMs ms: Int) {
        editor.openPreviewTab(for: asset, atSourceFrame: secondsToFrame(seconds: Double(ms) / 1000, rate: editor.timeline.frameRate))
    }
}

// MARK: - Unused footage

private struct UnusedFootageSection: View {
    @Environment(EditorViewModel.self) private var editor
    let board: NUEDITBackendClient.Board
    let model: StoryboardModel

    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.sm) {
            Text("Footage no beat uses")
                .font(.system(size: AppTheme.FontSize.sm, weight: AppTheme.FontWeight.semibold))
                .foregroundStyle(AppTheme.Text.secondaryColor)
                .padding(.top, AppTheme.Spacing.md)
            ForEach(Array(board.unusedFootage.enumerated()), id: \.offset) { _, footage in row(footage) }
        }
    }

    private func row(_ footage: NUEDITBackendClient.Board.UnusedFootage) -> some View {
        let asset = editor.asset(forFootageId: footage.footageId)
        return HStack(spacing: AppTheme.Spacing.sm) {
            StoryboardFrame(footageId: footage.footageId, frameMs: footage.frameMs, coverage: nil)
                .frame(width: AppTheme.Storyboard.matchThumbWidth, height: AppTheme.Storyboard.matchThumbHeight)
            VStack(alignment: .leading, spacing: AppTheme.Spacing.xxs) {
                Text(asset?.name ?? "Not in this project").lineLimit(1).foregroundStyle(AppTheme.Text.primaryColor)
                Text(footage.label?.isEmpty == false ? footage.label! : StoryboardTab.timing(Double(footage.endMs - footage.startMs) / 1000))
                    .lineLimit(2)
                    .foregroundStyle(AppTheme.Text.tertiaryColor)
            }
            Spacer(minLength: 0)
            Menu("Use") {
                Menu("Assign to Beat") {
                    ForEach(board.beats) { beat in
                        Button(beatTitle(beat)) {
                            model.assign(footage.footageId, startMs: footage.startMs, endMs: footage.endMs, to: beat.sectionId)
                        }
                    }
                }
                if footage.intentional, let override = unusedOverride(for: footage) {
                    Button("Stop Leaving Out") { model.undoOverride(override.overrideId) }
                } else {
                    Button("Leave Out on Purpose") { model.markUnused(footage.footageId, startMs: footage.startMs, endMs: footage.endMs) }
                }
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
        }
        .font(.system(size: AppTheme.FontSize.xs))
        .opacity(footage.intentional ? AppTheme.Opacity.muted : 1)
    }

    private func beatTitle(_ beat: NUEDITBackendClient.Board.Beat) -> String {
        let label = beat.label?.isEmpty == false ? beat.label! : "\(beat.order)"
        let visual = (beat.visual ?? "").prefix(40)
        return visual.isEmpty ? label : "\(label) — \(visual)"
    }

    private func unusedOverride(for footage: NUEDITBackendClient.Board.UnusedFootage) -> NUEDITBackendClient.Board.Override? {
        board.overrides.first { $0.action == "unused" && $0.footageId == footage.footageId }
    }
}

// MARK: - Frame

/// A frame of matched footage, read from this Mac's proxy (or original) at the tower's `frame_ms`.
private struct StoryboardFrame: View {
    @Environment(EditorViewModel.self) private var editor
    let footageId: String?
    let frameMs: Int?
    let coverage: NUEDITBackendClient.Board.Coverage?
    @State private var image: CGImage?

    private var source: URL? {
        guard let footageId, let asset = editor.asset(forFootageId: footageId) else { return nil }
        if let proxy = editor.previewProxyURLs[asset.id] { return proxy }
        return editor.missingMediaRefs.contains(asset.id) ? nil : asset.url
    }

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: AppTheme.Radius.sm).fill(AppTheme.Background.placeholderColor)
            if let image {
                Image(decorative: image, scale: 1).resizable().scaledToFill()
            } else {
                placeholder
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: AppTheme.Radius.sm))
        .task(id: "\(source?.path ?? "")|\(frameMs ?? -1)") {
            image = nil
            guard let source, let frameMs else { return }
            image = await StoryboardFrameCache.shared.frame(of: source, atMilliseconds: frameMs)
        }
    }

    @ViewBuilder
    private var placeholder: some View {
        if footageId == nil, let coverage {
            VStack(spacing: AppTheme.Spacing.xxs) {
                Image(systemName: coverage == .scriptGap ? "text.badge.xmark" : "film.stack")
                Text(coverage == .scriptGap ? "Script gap" : "No footage")
            }
            .font(.system(size: AppTheme.FontSize.xs))
            .foregroundStyle(StoryboardTab.color(coverage))
        } else if footageId != nil, source == nil {
            Image(systemName: "externaldrive.badge.questionmark")
                .font(.system(size: AppTheme.FontSize.sm))
                .foregroundStyle(AppTheme.Text.mutedColor)
                .help("This footage isn't available on this Mac")
        }
    }
}
