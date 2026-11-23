import SwiftUI
import UniformTypeIdentifiers

/// Refresh from source: the script was revised, so show what re-reading it would change — and
/// which matches and corrections it would cost — before anything changes.
struct StoryboardRefreshView: View {
    let model: StoryboardModel

    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.zero) {
            Text("Refresh Script")
                .font(.system(size: AppTheme.FontSize.lg, weight: AppTheme.FontWeight.semibold))
                .foregroundStyle(AppTheme.Text.primaryColor)
                .padding(AppTheme.Spacing.xl)
            Divider().opacity(AppTheme.Opacity.moderate)
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .padding(AppTheme.Spacing.xl)
            Divider().opacity(AppTheme.Opacity.moderate)
            footer.padding(AppTheme.Spacing.lg)
        }
        .frame(
            minWidth: AppTheme.ScriptImport.sheetMinWidth, idealWidth: AppTheme.ScriptImport.sheetIdealWidth,
            minHeight: AppTheme.ScriptImport.sheetMinHeight, idealHeight: AppTheme.ScriptImport.sheetIdealHeight
        )
        .background(AppTheme.Background.surfaceColor)
    }

    @ViewBuilder
    private var content: some View {
        switch model.refresh {
        case .none, .previewing:
            busy("Reading the script again…")
        case .applying:
            busy("Updating the storyboard…")
        case .needsFile:
            VStack(alignment: .leading, spacing: AppTheme.Spacing.md) {
                Text("This script was imported from a file. Choose the revised version.")
                    .font(.system(size: AppTheme.FontSize.md))
                    .foregroundStyle(AppTheme.Text.primaryColor)
                Button("Choose File…") { chooseFile() }
            }
        case .review(let report, _):
            review(report)
        }
    }

    private func review(_ report: NUEDITBackendClient.RefreshReport) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: AppTheme.Spacing.lg) {
                Text(summary(report))
                    .font(.system(size: AppTheme.FontSize.md, weight: AppTheme.FontWeight.medium))
                    .foregroundStyle(AppTheme.Text.primaryColor)
                let edited = report.beats.filter { $0.status != "unchanged" }
                if !edited.isEmpty {
                    section("Changes") {
                        ForEach(Array(edited.enumerated()), id: \.offset) { _, beat in
                            line("\(beat.label?.isEmpty == false ? beat.label! : "\(beat.order)")",
                                 beat.status == "added" ? "New beat" : "Changed: \(beat.changes.joined(separator: ", "))")
                        }
                    }
                }
                if !report.removedBeats.isEmpty {
                    section("Removed") {
                        ForEach(report.removedBeats, id: \.sectionId) { beat in
                            line(beat.label?.isEmpty == false ? beat.label! : "\(beat.order)", removedDetail(beat), warn: beat.matchesLost + beat.overridesLost > 0)
                        }
                    }
                }
                if !report.rematch.isEmpty {
                    caption("\(report.rematch.count) beat\(report.rematch.count == 1 ? "" : "s") will need matching again.")
                }
                ForEach(report.warnings, id: \.self) { warning in
                    Label(warning, systemImage: "exclamationmark.triangle")
                        .font(.system(size: AppTheme.FontSize.xs))
                        .foregroundStyle(AppTheme.Status.warningColor)
                }
            }
        }
    }

    private var footer: some View {
        HStack {
            Spacer()
            Button("Cancel") { model.dismissRefresh() }.keyboardShortcut(.cancelAction)
            if case .review(let report, _) = model.refresh {
                Button(report.added + report.changed + report.removed == 0 ? "Done" : "Apply") {
                    if report.added + report.changed + report.removed == 0 { model.dismissRefresh() } else { model.applyRefresh() }
                }
                .keyboardShortcut(.defaultAction)
            }
        }
    }

    private func summary(_ report: NUEDITBackendClient.RefreshReport) -> String {
        guard report.added + report.changed + report.removed > 0 else { return "The script hasn't changed." }
        var parts: [String] = []
        if report.changed > 0 { parts.append("\(report.changed) changed") }
        if report.added > 0 { parts.append("\(report.added) added") }
        if report.removed > 0 { parts.append("\(report.removed) removed") }
        return parts.joined(separator: ", ") + " · \(report.unchanged) unchanged"
    }

    private func removedDetail(_ beat: NUEDITBackendClient.RefreshReport.RemovedBeat) -> String {
        var lost: [String] = []
        if beat.matchesLost > 0 { lost.append("\(beat.matchesLost) match\(beat.matchesLost == 1 ? "" : "es")") }
        if beat.overridesLost > 0 { lost.append("\(beat.overridesLost) of your correction\(beat.overridesLost == 1 ? "" : "s")") }
        let visual = beat.visual?.isEmpty == false ? beat.visual! : "Beat removed"
        return lost.isEmpty ? visual : "\(visual) — loses \(lost.joined(separator: " and "))"
    }

    private func section<Content: View>(_ title: String, @ViewBuilder _ rows: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.xs) {
            Text(title)
                .font(.system(size: AppTheme.FontSize.sm, weight: AppTheme.FontWeight.semibold))
                .foregroundStyle(AppTheme.Text.secondaryColor)
            rows()
        }
    }

    private func line(_ label: String, _ detail: String, warn: Bool = false) -> some View {
        HStack(alignment: .top, spacing: AppTheme.Spacing.md) {
            Text(label)
                .frame(width: AppTheme.ScriptImport.beatLabelWidth, alignment: .leading)
                .foregroundStyle(AppTheme.Text.tertiaryColor)
            Text(detail)
                .foregroundStyle(warn ? AppTheme.Status.warningColor : AppTheme.Text.primaryColor)
                .fixedSize(horizontal: false, vertical: true)
        }
        .font(.system(size: AppTheme.FontSize.sm))
    }

    private func busy(_ text: String) -> some View {
        HStack(spacing: AppTheme.Spacing.sm) {
            ProgressView().controlSize(.small)
            caption(text)
        }
    }

    private func caption(_ text: String) -> some View {
        Text(text)
            .font(.system(size: AppTheme.FontSize.xs))
            .foregroundStyle(AppTheme.Text.tertiaryColor)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func chooseFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.commaSeparatedText, .html] + [UTType(filenameExtension: "xlsx")].compactMap { $0 }
        panel.allowsMultipleSelection = false
        panel.message = "Choose the revised script"
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            model.previewRefresh(file: url)
        }
    }
}
