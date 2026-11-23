import SwiftUI
import UniformTypeIdentifiers

/// File ▸ Import Script…: hand NUEDIT an AV script (Google Sheets / Docs link, CSV, XLSX, HTML),
/// confirm how its columns were read, and import it as storyboard beats.
struct ScriptImportView: View {
    @Environment(EditorViewModel.self) private var editor
    @State private var model: ScriptImportModel?

    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.zero) {
            Text("Import Script")
                .font(.system(size: AppTheme.FontSize.lg, weight: AppTheme.FontWeight.semibold))
                .foregroundStyle(AppTheme.Text.primaryColor)
                .padding(AppTheme.Spacing.xl)
            Divider().opacity(AppTheme.Opacity.moderate)
            Group {
                if let model { content(model) } else { Color.clear }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .padding(AppTheme.Spacing.xl)
            Divider().opacity(AppTheme.Opacity.moderate)
            if let model { footer(model).padding(AppTheme.Spacing.lg) }
        }
        .frame(
            minWidth: AppTheme.ScriptImport.sheetMinWidth, idealWidth: AppTheme.ScriptImport.sheetIdealWidth,
            minHeight: AppTheme.ScriptImport.sheetMinHeight, idealHeight: AppTheme.ScriptImport.sheetIdealHeight
        )
        .background(AppTheme.Background.surfaceColor)
        .onAppear { if model == nil { model = ScriptImportModel(projectId: editor.towerProjectId) } }
        .onDisappear { model?.cancel() }
    }

    // MARK: - Steps

    @ViewBuilder
    private func content(_ model: ScriptImportModel) -> some View {
        if model.projectId == nil {
            notice(
                "This project isn't linked to a NUEDIT project yet, so a script has nowhere to go.",
                detail: "NUEDIT links a project with the tower_link tool. Scripts import once it has."
            )
        } else {
            switch model.phase {
            case .source: sourceStep(model)
            case .detecting: busy("Reading the script…")
            case .importing: busy("Importing…")
            case .review: reviewStep(model)
            case .done: doneStep(model)
            case .failed(let message): notice(message, detail: nil, isError: true)
            }
        }
    }

    private func sourceStep(_ model: ScriptImportModel) -> some View {
        @Bindable var model = model
        return VStack(alignment: .leading, spacing: AppTheme.Spacing.lg) {
            caption("Paste a Google Sheets or Google Docs link, shared “Anyone with the link” or published to the web.")
            TextField("https://docs.google.com/…", text: $model.linkText)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: AppTheme.FontSize.sm).monospaced())
                .onSubmit { model.detect() }
            HStack(spacing: AppTheme.Spacing.sm) {
                caption("Or choose a CSV, Excel (.xlsx), or web page (.html) export:")
                Button("Choose File…") { chooseFile(into: model) }
            }
            if let file = model.file {
                HStack(spacing: AppTheme.Spacing.xs) {
                    Image(systemName: "doc.text")
                    Text(file.lastPathComponent)
                    Button("Remove") { model.file = nil }.buttonStyle(.link)
                }
                .font(.system(size: AppTheme.FontSize.sm))
                .foregroundStyle(AppTheme.Text.secondaryColor)
            }
        }
    }

    private func reviewStep(_ model: ScriptImportModel) -> some View {
        @Bindable var model = model
        return ScrollView {
            VStack(alignment: .leading, spacing: AppTheme.Spacing.lg) {
                if let scripts = model.preview?.scripts, scripts.count > 1 {
                    Picker("Script", selection: $model.selectedScript) {
                        ForEach(scripts.indices, id: \.self) { Text(scripts[$0].title).tag($0) }
                    }
                    .fixedSize()
                    caption("This document has \(scripts.count) script tables; each imports as its own script.")
                }
                if let script = model.reviewedScript {
                    summary(script)
                    columnsSection(script, model: model)
                    beatsSection(script)
                    warnings((model.preview?.warnings ?? []) + script.warnings)
                }
            }
        }
    }

    private func doneStep(_ model: ScriptImportModel) -> some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.md) {
            let scripts = model.imported?.scripts ?? []
            Text("Imported \(scripts.count) script\(scripts.count == 1 ? "" : "s") into NUEDIT.")
                .font(.system(size: AppTheme.FontSize.md, weight: AppTheme.FontWeight.medium))
                .foregroundStyle(AppTheme.Text.primaryColor)
            ForEach(scripts.indices, id: \.self) { index in
                let script = scripts[index]
                Text("\(script.title) — \(script.beatCount) beat\(script.beatCount == 1 ? "" : "s")\(script.totalSeconds.map { ", \(Self.duration($0))" } ?? "")")
                    .font(.system(size: AppTheme.FontSize.sm))
                    .foregroundStyle(AppTheme.Text.secondaryColor)
            }
            caption("The storyboard — footage matched to each beat, and the gaps — appears once NUEDIT finishes its coverage pass.")
            warnings(model.imported?.warnings ?? [])
        }
    }

    // MARK: - Review parts

    private func summary(_ script: NUEDITBackendClient.ImportedScript) -> some View {
        var parts = ["Header on row \(script.headerRow)", "\(script.beatCount) beat\(script.beatCount == 1 ? "" : "s")"]
        if let total = script.totalSeconds { parts.append(Self.duration(total)) }
        return VStack(alignment: .leading, spacing: AppTheme.Spacing.xxs) {
            Text(script.title)
                .font(.system(size: AppTheme.FontSize.md, weight: AppTheme.FontWeight.semibold))
                .foregroundStyle(AppTheme.Text.primaryColor)
            caption(parts.joined(separator: " · "))
        }
    }

    private func columnsSection(_ script: NUEDITBackendClient.ImportedScript, model: ScriptImportModel) -> some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.xs) {
            sectionTitle("Columns")
            caption("Check how each column was read. Change one, then update the preview before importing.")
            ForEach(script.columns.map(\.header) + script.unmapped, id: \.self) { header in
                HStack {
                    Text(header)
                        .font(.system(size: AppTheme.FontSize.sm))
                        .foregroundStyle(AppTheme.Text.primaryColor)
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Picker("", selection: Binding(
                        get: { model.pendingRole(ofColumn: header) },
                        set: { model.assign($0, toColumn: header) }
                    )) {
                        Text("Ignore").tag(ScriptImportModel.Role?.none)
                        ForEach(ScriptImportModel.Role.allCases, id: \.self) { role in
                            Text(Self.roleName(role)).tag(ScriptImportModel.Role?.some(role))
                        }
                    }
                    .labelsHidden()
                    .frame(width: AppTheme.ScriptImport.rolePickerWidth)
                }
            }
        }
    }

    private func beatsSection(_ script: NUEDITBackendClient.ImportedScript) -> some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.xs) {
            sectionTitle(script.beatCount > script.beats.count ? "First \(script.beats.count) beats" : "Beats")
            ForEach(script.beats.prefix(8), id: \.order) { beat in
                HStack(alignment: .top, spacing: AppTheme.Spacing.md) {
                    Text(beat.label.isEmpty ? "\(beat.order)" : beat.label)
                        .frame(width: AppTheme.ScriptImport.beatLabelWidth, alignment: .leading)
                        .foregroundStyle(AppTheme.Text.tertiaryColor)
                    VStack(alignment: .leading, spacing: AppTheme.Spacing.xxs) {
                        if beat.scriptGap {
                            Text("No visual description — a gap in the script")
                                .foregroundStyle(AppTheme.Status.warningColor)
                        } else {
                            Text(beat.visual).foregroundStyle(AppTheme.Text.primaryColor)
                        }
                        if !beat.audio.isEmpty {
                            Text(beat.audio).foregroundStyle(AppTheme.Text.secondaryColor)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    Text(beat.durationSeconds.map(Self.duration) ?? "—")
                        .foregroundStyle(AppTheme.Text.tertiaryColor)
                }
                .font(.system(size: AppTheme.FontSize.sm))
                .lineLimit(3)
            }
        }
    }

    @ViewBuilder
    private func warnings(_ messages: [String]) -> some View {
        if !messages.isEmpty {
            VStack(alignment: .leading, spacing: AppTheme.Spacing.xxs) {
                ForEach(messages, id: \.self) { message in
                    Label(message, systemImage: "exclamationmark.triangle")
                        .font(.system(size: AppTheme.FontSize.xs))
                        .foregroundStyle(AppTheme.Status.warningColor)
                }
            }
        }
    }

    // MARK: - Footer

    private func footer(_ model: ScriptImportModel) -> some View {
        HStack {
            Spacer()
            switch model.phase {
            case .source:
                Button("Cancel") { editor.showScriptImport = false }.keyboardShortcut(.cancelAction)
                Button("Read Script") { model.detect() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(model.source == nil || model.projectId == nil)
            case .review:
                Button("Back") { model.startOver() }
                if model.isPreviewCurrent {
                    let count = model.preview?.scripts.count ?? 0
                    Button(count > 1 ? "Import \(count) Scripts" : "Import") { model.importScripts() }
                        .keyboardShortcut(.defaultAction)
                } else {
                    Button("Update Preview") { model.detect() }.keyboardShortcut(.defaultAction)
                }
            case .detecting, .importing:
                Button("Cancel") { model.cancel(); model.backToReview() }.keyboardShortcut(.cancelAction)
            case .failed:
                Button("Back") { model.backToReview() }.keyboardShortcut(.cancelAction)
            case .done:
                Button("Done") {
                    editor.showScriptImport = false
                    editor.storyboard.reload()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
    }

    // MARK: - Pieces

    private func busy(_ text: String) -> some View {
        HStack(spacing: AppTheme.Spacing.sm) {
            ProgressView().controlSize(.small)
            caption(text)
        }
    }

    private func notice(_ message: String, detail: String?, isError: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.xs) {
            Text(message)
                .font(.system(size: AppTheme.FontSize.md))
                .foregroundStyle(isError ? AppTheme.Status.errorColor : AppTheme.Text.primaryColor)
                .fixedSize(horizontal: false, vertical: true)
            if let detail { caption(detail) }
        }
    }

    private func sectionTitle(_ text: String) -> some View {
        Text(text)
            .font(.system(size: AppTheme.FontSize.sm, weight: AppTheme.FontWeight.semibold))
            .foregroundStyle(AppTheme.Text.secondaryColor)
    }

    private func caption(_ text: String) -> some View {
        Text(text)
            .font(.system(size: AppTheme.FontSize.xs))
            .foregroundStyle(AppTheme.Text.tertiaryColor)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func chooseFile(into model: ScriptImportModel) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.commaSeparatedText, .html]
            + [UTType(filenameExtension: "xlsx")].compactMap { $0 }
        panel.allowsMultipleSelection = false
        panel.message = "Choose the script exported from your spreadsheet or document"
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            model.file = url
        }
    }

    private static func roleName(_ role: ScriptImportModel.Role) -> String {
        switch role {
        case .label: "Shot #"
        case .scene: "Scene"
        case .visual: "Visual"
        case .audio: "Audio / VO"
        case .onScreenText: "On-screen text"
        case .sound: "SFX / Music"
        case .duration: "Duration / Time"
        case .notes: "Notes"
        }
    }

    private static func duration(_ seconds: Double) -> String {
        seconds < 60 ? String(format: "%.1fs", seconds) : String(format: "%d:%04.1f", Int(seconds) / 60, seconds.truncatingRemainder(dividingBy: 60))
    }
}
