import Foundation

/// Drives the script import sheet: pick a source, review the tower's column detection, import.
///
/// NUEDIT parses and stores; this only holds what the sheet shows. A preview is always a dry run
/// with the current mapping, and Import is offered only while the preview still matches it.
@Observable
@MainActor
final class ScriptImportModel {
    typealias Role = NUEDITBackendClient.ScriptColumnRole
    typealias Response = NUEDITBackendClient.ScriptImportResponse

    enum Phase: Equatable {
        case source
        case detecting
        case review
        case importing
        case done
        case failed(String)
    }

    var linkText = "" {
        didSet { if !linkText.isEmpty { file = nil } }
    }
    var file: URL? {
        didSet { if file != nil { linkText = "" } }
    }
    var selectedScript = 0

    private(set) var phase: Phase = .source
    private(set) var preview: Response?
    private(set) var imported: Response?
    private(set) var mapping: [Role: String?] = [:]
    private var previewMapping: [Role: String?]?
    private var work: Task<Void, Never>?

    /// The NUEDIT project scripts go to; nil means this project isn't linked to the tower.
    let projectId: String?
    private let client: NUEDITBackendClient

    init(projectId: String?, client: NUEDITBackendClient = .shared) {
        self.projectId = projectId
        self.client = client
    }

    var source: NUEDITBackendClient.ScriptSource? {
        if let file { return .file(file) }
        let link = linkText.trimmingCharacters(in: .whitespacesAndNewlines)
        return link.isEmpty ? nil : .link(link)
    }

    var isPreviewCurrent: Bool { preview != nil && previewMapping == mapping }

    /// The request in flight, so a caller can await its result.
    var pendingWork: Task<Void, Never>? { work }

    var reviewedScript: NUEDITBackendClient.ImportedScript? {
        guard let scripts = preview?.scripts, scripts.indices.contains(selectedScript) else { return nil }
        return scripts[selectedScript]
    }

    /// Gives `role` to the column titled `header`; nil takes that column's role away. Nothing is
    /// sent until the preview is updated.
    func assign(_ role: Role?, toColumn header: String) {
        let current = reviewedScript?.columns.first { $0.header == header }?.role
        guard role != current else { return }
        if let role {
            mapping[role] = .some(header)
        } else if let current {
            mapping[current] = .some(nil)
        }
    }

    /// The role a column will have once the preview is updated: the pending mapping first, then the tower's detection.
    func pendingRole(ofColumn header: String) -> Role? {
        if let pinned = mapping.first(where: { $0.value == header })?.key { return pinned }
        guard let detected = reviewedScript?.columns.first(where: { $0.header == header })?.role else { return nil }
        if case .some(.none) = mapping[detected] { return nil }
        if case .some(.some(let other)) = mapping[detected], other != header { return nil }
        return detected
    }

    func detect() {
        guard let projectId, let source else { return }
        let mapping = mapping
        run(.detecting) { [client] in
            let response = try await client.importScript(projectId: projectId, source: source, mapping: mapping, dryRun: true)
            return { model in
                model.preview = response
                model.previewMapping = mapping
                model.selectedScript = min(model.selectedScript, max(response.scripts.count - 1, 0))
                model.phase = .review
            }
        }
    }

    func importScripts() {
        guard let projectId, let source, isPreviewCurrent else { return }
        let mapping = mapping
        run(.importing) { [client] in
            let response = try await client.importScript(projectId: projectId, source: source, mapping: mapping, dryRun: false)
            return { model in
                model.imported = response
                model.phase = .done
            }
        }
    }

    /// Back to choosing a source; the mapping is per source, so it starts over.
    func startOver() {
        cancel()
        preview = nil
        previewMapping = nil
        mapping = [:]
        selectedScript = 0
        phase = .source
    }

    func backToReview() {
        phase = preview == nil ? .source : .review
    }

    func cancel() {
        work?.cancel()
        work = nil
    }

    private func run(_ busy: Phase, _ operation: @escaping @Sendable () async throws -> @MainActor (ScriptImportModel) -> Void) {
        cancel()
        let resume = phase
        phase = busy
        work = Task { @MainActor [weak self] in
            do {
                let apply = try await operation()
                guard let self, !Task.isCancelled else { return }
                apply(self)
            } catch is CancellationError {
                self?.phase = resume
            } catch {
                guard let self, !Task.isCancelled else { return }
                self.phase = .failed(error.localizedDescription)
            }
            self?.work = nil
        }
    }
}
