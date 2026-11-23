import Foundation

/// The storyboard panel's state: the linked NUEDIT project's scripts, the selected script's board,
/// and the tower jobs (matching, re-captioning) the user starts from it.
///
/// Owned by the editor so the board and a running job outlive switching panel tabs. NUEDIT holds
/// every beat, match and override; this only mirrors the last board it returned.
@Observable
@MainActor
final class StoryboardModel {
    typealias Board = NUEDITBackendClient.Board

    enum Status: Equatable {
        case idle
        case loading
        case ready
        case failed(String)
    }

    enum Job: Equatable {
        case none
        case matching
        case recaptioning(done: Int, total: Int)
    }

    private(set) var scripts: [NUEDITBackendClient.ScriptSummary] = []
    private(set) var selectedScriptId: String?
    private(set) var board: Board?
    private(set) var status: Status = .idle
    private(set) var job: Job = .none
    /// The last thing that went wrong or needs saying; shown above the board, cleared by the next action.
    private(set) var message: String?

    var pollInterval: Duration = .seconds(2)
    /// Consecutive failed progress polls tolerated before a job is reported as lost.
    static let pollFailureLimit = 5

    private let projectId: @MainActor () -> String?
    private let client: NUEDITBackendClient
    private var loadWork: Task<Void, Never>?
    private var jobWork: Task<Void, Never>?
    private var correctionWork: Task<Void, Never>?

    init(client: NUEDITBackendClient = .shared, projectId: @escaping @MainActor () -> String?) {
        self.client = client
        self.projectId = projectId
    }

    var isLinked: Bool { projectId() != nil }

    // MARK: - Loading

    /// Reloads the script list, keeps the selection when it still exists, then loads its board.
    func reload() {
        guard let projectId = projectId() else {
            status = .idle
            return
        }
        message = nil
        loadWork?.cancel()
        status = .loading
        loadWork = Task { @MainActor [weak self, client] in
            do {
                let scripts = try await client.scripts(projectId: projectId)
                guard let self, !Task.isCancelled else { return }
                self.scripts = scripts
                if self.selectedScriptId.map({ id in scripts.contains { $0.id == id } }) != true {
                    self.selectedScriptId = scripts.last?.id
                }
                guard let scriptId = self.selectedScriptId else {
                    self.board = nil
                    self.status = .ready
                    return
                }
                let board = try await client.board(scriptId: scriptId)
                guard !Task.isCancelled, self.selectedScriptId == scriptId else { return }
                self.board = board
                self.status = .ready
            } catch is CancellationError {
            } catch {
                guard let self, !Task.isCancelled else { return }
                self.status = .failed(error.localizedDescription)
            }
        }
    }

    func select(scriptId: String) {
        guard scriptId != selectedScriptId else { return }
        selectedScriptId = scriptId
        board = nil
        reload()
    }

    // MARK: - Corrections

    /// This footage range is the beat.
    func assign(_ footageId: String, startMs: Int?, endMs: Int?, to beatId: String) {
        override(.assign, beatId: beatId, footageId: footageId, startMs: startMs, endMs: endMs)
    }

    /// Not this footage range for the beat.
    func reject(_ footageId: String, startMs: Int?, endMs: Int?, for beatId: String) {
        override(.reject, beatId: beatId, footageId: footageId, startMs: startMs, endMs: endMs)
    }

    /// This footage range is left out on purpose.
    func markUnused(_ footageId: String, startMs: Int?, endMs: Int?) {
        override(.unused, beatId: nil, footageId: footageId, startMs: startMs, endMs: endMs)
    }

    func undoOverride(_ overrideId: String) {
        guard let scriptId = selectedScriptId else { return }
        apply { client in try await client.removeOverride(scriptId: scriptId, overrideId: overrideId) }
    }

    private func override(
        _ action: NUEDITBackendClient.OverrideAction, beatId: String?, footageId: String, startMs: Int?, endMs: Int?
    ) {
        guard let scriptId = selectedScriptId else { return }
        apply { client in
            try await client.addOverride(
                scriptId: scriptId, action: action, beatId: beatId, footageId: footageId, startMs: startMs, endMs: endMs
            )
        }
    }

    /// Corrections return the whole updated board; it replaces ours only if the script is still selected.
    private func apply(_ change: @escaping @Sendable (NUEDITBackendClient) async throws -> Board) {
        guard let scriptId = selectedScriptId else { return }
        message = nil
        let previous = correctionWork
        // Corrections apply in the order they were made; each returns the whole board.
        correctionWork = Task { @MainActor [weak self, client] in
            await previous?.value
            do {
                let board = try await change(client)
                guard let self, self.selectedScriptId == scriptId else { return }
                self.board = board
            } catch {
                self?.message = error.localizedDescription
            }
        }
    }

    // MARK: - Jobs

    /// Matches every beat to the project's footage, then reloads the board.
    func runMatching() {
        guard job == .none, let projectId = projectId(), let scriptId = selectedScriptId else { return }
        message = nil
        job = .matching
        jobWork = Task { @MainActor [weak self, client] in
            do {
                // The tower's match events accumulate across runs: follow only this one.
                let baseline = try await client.matchProgress(scriptId: scriptId, since: 0).latestSequence
                try await client.startMatching(scriptId: scriptId, projectId: projectId)
                let failure = try await self?.follow(since: baseline) { since in
                    try await client.matchProgress(scriptId: scriptId, since: since)
                } failedEvent: { $0 == "match_failed" }
                guard let self, !Task.isCancelled else { return }
                self.job = .none
                if let failure { self.message = "Matching failed: \(failure)" }
                self.reload()
            } catch is CancellationError {
            } catch {
                guard let self, !Task.isCancelled else { return }
                self.job = .none
                self.message = error.localizedDescription
            }
        }
    }

    /// Describes footage the captioner hasn't, so matching can see it.
    func recaption() {
        guard job == .none, let projectId = projectId() else { return }
        message = nil
        job = .recaptioning(done: 0, total: 0)
        jobWork = Task { @MainActor [weak self, client] in
            do {
                let start = try await client.startRecaption(projectId: projectId)
                guard let self, !Task.isCancelled else { return }
                guard start.status == "queued" else {
                    self.job = .none
                    self.message = "Every file is already described."
                    return
                }
                self.job = .recaptioning(done: 0, total: start.footageCount)
                let failure = try await self.follow(since: start.sinceSequence) { since in
                    try await client.recaptionProgress(projectId: projectId, since: since)
                } failedEvent: { $0 == "recaption_failed" }
                guard !Task.isCancelled else { return }
                self.job = .none
                self.message = failure.map { "Describing footage failed: \($0)" }
                    ?? "Footage described. Run matching to update the board."
            } catch is CancellationError {
            } catch {
                guard let self, !Task.isCancelled else { return }
                self.job = .none
                self.message = error.localizedDescription
            }
        }
    }

    /// Polls a tower job to completion; returns the failure reason, or nil on success.
    private func follow(
        since start: Int,
        poll: @escaping @Sendable (Int) async throws -> NUEDITBackendClient.JobProgress,
        failedEvent: (String) -> Bool
    ) async throws -> String? {
        var since = start
        var failures = 0
        while true {
            try Task.checkCancellation()
            do {
                let progress = try await poll(since)
                failures = 0
                since = progress.latestSequence
                absorb(progress.events)
                if let failed = progress.events.last(where: { failedEvent($0.event) }) {
                    if case .string(let reason)? = failed.payload?["error"] { return reason }
                    return "the tower reported a failure"
                }
                if progress.isComplete { return nil }
            } catch let error as CancellationError {
                throw error
            } catch {
                failures += 1
                if failures >= Self.pollFailureLimit { throw error }
            }
            try await Task.sleep(for: pollInterval)
        }
    }

    private func absorb(_ events: [NUEDITBackendClient.JobProgress.Event]) {
        guard case .recaptioning(_, let total) = job,
              let latest = events.last(where: { $0.event == "recaption_progress" }) else { return }
        // Payload dictionary keys arrive camel-cased by the snake-case decoder.
        let done = latest.payload?["footageDone"]?.number.map(Int.init) ?? 0
        let reportedTotal = latest.payload?["footageTotal"]?.number.map(Int.init) ?? total
        job = .recaptioning(done: done, total: reportedTotal)
    }

    /// Project close: stop polling and drop in-flight loads.
    func cancelAll() {
        loadWork?.cancel()
        jobWork?.cancel()
        correctionWork?.cancel()
        loadWork = nil
        jobWork = nil
        correctionWork = nil
        job = .none
    }

    /// The request or job in flight, so a caller can await it.
    var pendingWork: [Task<Void, Never>] { [loadWork, jobWork, correctionWork].compactMap { $0 } }
}
