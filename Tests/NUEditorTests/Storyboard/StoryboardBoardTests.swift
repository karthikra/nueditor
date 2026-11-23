import Foundation
import Synchronization
import Testing
@testable import NUEditor

/// A tower stand-in that answers the board routes the way NUEDIT does.
private final class FakeTower: Sendable {
    struct Call: Sendable { let method: String; let path: String; let query: String?; let body: Data? }

    private let state = Mutex<(calls: [Call], matchEvents: [Data], recaptionEvents: [Data], recaptionStatus: String)>(
        ([], [], [], "queued")
    )
    private let fileSourced = Mutex(false)

    func makeFileSourced() { fileSourced.withLock { $0 = true } }

    static var refreshReport: [String: Any] { [
        "script_id": "s-1", "dry_run": true, "added": 1, "changed": 1, "unchanged": 1, "removed": 1,
        "beats": [["order": 1, "label": "1", "status": "unchanged", "section_id": "b-1", "changes": [], "paired_by": "text", "text_similarity": 1.0],
                  ["order": 2, "label": "2", "status": "changed", "section_id": "b-2", "changes": ["visual"], "paired_by": "similar", "text_similarity": 0.8],
                  ["order": 3, "label": "2A", "status": "added", "section_id": NSNull(), "changes": [], "paired_by": NSNull(), "text_similarity": NSNull()]],
        "removed_beats": [["section_id": "b-3", "order": 3, "label": "3", "visual": "", "matches_lost": 0, "overrides_lost": 1]],
        "rematch": ["b-2", "b-new"], "warnings": [],
    ] }

    private static func encode(_ events: [[String: Any]]) -> [Data] { events.map { json($0) } }
    private static func decode(_ events: [Data]) -> [[String: Any]] {
        events.compactMap { (try? JSONSerialization.jsonObject(with: $0)) as? [String: Any] }
    }
    let host: String

    init() {
        host = "\(UUID().uuidString.lowercased()).stub.test"
        StubHTTP.register(host: host) { [weak self] request in
            self?.answer(request) ?? (500, Data())
        }
    }

    var calls: [Call] { state.withLock { $0.calls } }

    func seedPriorMatchRun() {
        let prior = Self.encode([["sequence": 7, "event": "match_ready", "status": "completed", "payload": [:]]])
        state.withLock { $0.matchEvents = prior }
    }

    func setRecaptionStatus(_ status: String) { state.withLock { $0.recaptionStatus = status } }

    func client() async -> NUEDITBackendClient {
        let client = NUEDITBackendClient(session: StubHTTP.session())
        await client.use(NUEDITBackendSettings(baseURL: URL(string: "http://\(host)"), agentKey: .value("k")))
        return client
    }

    static func json(_ object: Any) -> Data { (try? JSONSerialization.data(withJSONObject: object)) ?? Data() }

    static func board(matching: String = "done", assigned: Bool = false) -> [String: Any] {
        var matches: [[String: Any]] = [[
            "footage_id": "f-1", "start_ms": 1000, "end_ms": 4000, "frame_ms": 2500, "confidence": 0.82,
            "source": "auto", "match_id": "m-1", "chunk_id": "c-1", "override_id": NSNull(), "label": "denim close-up",
        ]]
        if assigned {
            matches.insert(["footage_id": "f-2", "start_ms": 0, "end_ms": 2000, "frame_ms": 1000, "confidence": NSNull(),
                            "source": "override", "match_id": NSNull(), "chunk_id": NSNull(), "override_id": "o-1", "label": ""], at: 0)
        }
        return [
            "script_id": "s-1", "title": "Denim 30s", "project_id": "p-1", "threshold": 0.5, "weak_floor": 0.05,
            "matching": matching, "counts": ["covered": 1, "weak": 0, "missing": 1, "script_gap": 1],
            "beats": [
                ["section_id": "b-1", "order": 1, "label": "1", "scene": "SCENE 1", "visual": "Close on denim",
                 "audio": "Made to last.", "on_screen_text": "", "sound": "", "notes": "", "duration_seconds": 3.0,
                 "coverage": "covered", "best_confidence": 0.82, "matches": matches, "placeholder": NSNull()],
                ["section_id": "b-2", "order": 2, "label": "2", "scene": "SCENE 1", "visual": "Rider on rooftop",
                 "audio": "", "on_screen_text": "", "sound": "", "notes": "", "duration_seconds": NSNull(),
                 "coverage": "missing", "best_confidence": NSNull(), "matches": [], "placeholder": NSNull()],
                ["section_id": "b-3", "order": 3, "label": "3", "scene": "", "visual": "", "audio": "Not for a season.",
                 "on_screen_text": "", "sound": "", "notes": "", "duration_seconds": 4.0,
                 "coverage": "script_gap", "best_confidence": NSNull(), "matches": [], "placeholder": NSNull()],
            ],
            "unused_footage": [["footage_id": "f-3", "chunk_id": "c-9", "start_ms": 0, "end_ms": 5000, "frame_ms": 2500,
                                "label": "colour bars", "intentional": false]],
            "overrides": assigned ? [["override_id": "o-1", "beat_id": "b-1", "action": "assign", "footage_id": "f-2",
                                      "start_ms": 0, "end_ms": 2000]] : [],
        ]
    }

    private func answer(_ request: URLRequest) -> (Int, Data) {
        let method = request.httpMethod ?? "GET"
        let components = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)
        let path = components?.path ?? ""
        let since = Int(components?.queryItems?.first { $0.name == "since_sequence" }?.value ?? "0") ?? 0
        state.withLock { $0.calls.append(Call(method: method, path: path, query: components?.query, body: request.httpBody)) }

        switch (method, path) {
        case ("GET", "/api/v1/projects/p-1/scripts"):
            return (200, Self.json([["id": "s-0", "title": "Old cut", "active_iteration": "v1", "created_at": "2026-11-20"],
                                    ["id": "s-1", "title": "Denim 30s", "active_iteration": "v1", "created_at": "2026-11-23"]]))
        case ("POST", "/api/v1/scripts/s-1/refresh"):
            let multipart = request.value(forHTTPHeaderField: "Content-Type")?.hasPrefix("multipart/") == true
            if fileSourced.withLock({ $0 }), !multipart {
                return (422, Self.json(["detail": ["code": "file_required", "message": "Send the revised file."]]))
            }
            return (200, Self.json(Self.refreshReport))
        case ("GET", "/api/v1/scripts/s-1/board"):
            return (200, Self.json(Self.board()))
        case ("POST", "/api/v1/scripts/s-1/board/overrides"):
            return (200, Self.json(Self.board(assigned: true)))
        case ("DELETE", "/api/v1/scripts/s-1/board/overrides/o-1"):
            return (200, Self.json(Self.board()))
        case ("POST", "/api/v1/scripts/s-1/match"):
            let run = Self.encode([["sequence": 8, "event": "match_started", "status": "processing", "payload": [:]],
                                   ["sequence": 9, "event": "match_ready", "status": "completed", "payload": ["matched": 2]]])
            state.withLock { $0.matchEvents += run }
            return (202, Self.json(["script_id": "s-1", "status": "matching"]))
        case ("GET", "/api/v1/scripts/s-1/match_webhooks"):
            let events = Self.decode(state.withLock { $0.matchEvents }).filter { ($0["sequence"] as? Int ?? 0) > since }
            let latest = events.compactMap { $0["sequence"] as? Int }.max() ?? since
            let complete = events.contains { ["match_ready", "match_failed"].contains($0["event"] as? String) }
            return (200, Self.json(["script_id": "s-1", "events": events, "latest_sequence": latest, "is_complete": complete]))
        case ("POST", "/api/v1/projects/p-1/recaption"):
            let status = state.withLock { $0.recaptionStatus }
            if status == "nothing_to_do" {
                return (200, Self.json(["project_id": "p-1", "status": status, "footage_count": 0, "footage_ids": [], "since_sequence": 3]))
            }
            let run = Self.encode([
                ["sequence": 4, "event": "recaption_progress", "status": "processing",
                 "payload": ["footage_done": 1, "footage_total": 2, "described": 4, "failed": 0]],
                ["sequence": 5, "event": "recaption_ready", "status": "completed", "payload": ["footage_done": 2, "footage_total": 2]],
            ])
            state.withLock { $0.recaptionEvents = run }
            return (202, Self.json(["project_id": "p-1", "status": "queued", "footage_count": 2, "footage_ids": ["f-1", "f-3"], "since_sequence": 3]))
        case ("GET", "/api/v1/projects/p-1/recaption_webhooks"):
            let events = Self.decode(state.withLock { $0.recaptionEvents }).filter { ($0["sequence"] as? Int ?? 0) > since }
            let latest = events.compactMap { $0["sequence"] as? Int }.max() ?? since
            return (200, Self.json(["project_id": "p-1", "running": false, "events": events, "latest_sequence": latest,
                                    "is_complete": events.contains { $0["event"] as? String == "recaption_ready" }]))
        default:
            return (404, Self.json(["detail": "not stubbed: \(method) \(path)"]))
        }
    }
}

@Suite("Storyboard — board client")
struct StoryboardBoardClientTests {
    @Test func theBoardDecodesWithCoverageMatchesAndUnusedFootage() async throws {
        let tower = FakeTower()
        let board = try await tower.client().board(scriptId: "s-1")
        #expect(board.matching == .done && board.threshold == 0.5 && board.weakFloor == 0.05)
        #expect(board.counts.scriptGap == 1)
        #expect(board.beats.map(\.coverage) == [.covered, .missing, .scriptGap])
        let match = try #require(board.beats.first?.matches.first)
        #expect(match.footageId == "f-1" && match.frameMs == 2500 && match.source == .auto && match.confidence == 0.82)
        #expect(board.beats[1].durationSeconds == nil)
        #expect(board.unusedFootage.first?.label == "colour bars")
    }

    @Test func anAssignmentSendsTheBeatFootageAndRange() async throws {
        let tower = FakeTower()
        let board = try await tower.client().addOverride(
            scriptId: "s-1", action: .assign, beatId: "b-1", footageId: "f-2", startMs: 0, endMs: 2000
        )
        let call = try #require(tower.calls.last)
        let body = try #require(try JSONSerialization.jsonObject(with: call.body ?? Data()) as? [String: Any])
        #expect(body["action"] as? String == "assign" && body["beat_id"] as? String == "b-1")
        #expect(body["footage_id"] as? String == "f-2" && body["start_ms"] as? Int == 0 && body["end_ms"] as? Int == 2000)
        #expect(board.beats.first?.matches.first?.source == .override)
    }

    // The tower's match route takes the project as a query parameter, not a body.
    @Test func matchingNamesTheProjectInTheQuery() async throws {
        let tower = FakeTower()
        try await tower.client().startMatching(scriptId: "s-1", projectId: "p-1")
        #expect(tower.calls.last?.query == "project_id=p-1")
    }
}

@Suite("Storyboard — panel model")
@MainActor
struct StoryboardModelTests {
    private func model(_ tower: FakeTower, linked: Bool = true) async -> StoryboardModel {
        let model = StoryboardModel(client: await tower.client()) { linked ? "p-1" : nil }
        model.pollInterval = .zero
        return model
    }

    /// Awaits everything in flight, including work that finished work starts (a job reloads the board).
    private func settle(_ model: StoryboardModel) async {
        for _ in 0..<5 {
            for work in model.pendingWork { await work.value }
        }
    }

    @Test func loadingSelectsTheNewestScriptAndShowsItsBoard() async {
        let tower = FakeTower()
        let model = await model(tower)
        model.reload()
        await settle(model)
        #expect(model.scripts.map(\.id) == ["s-0", "s-1"])
        #expect(model.selectedScriptId == "s-1")
        #expect(model.board?.beats.count == 3)
        #expect(model.status == .ready)
    }

    // An earlier finished run must not read as this run being done.
    @Test func matchingFollowsOnlyItsOwnRunThenReloads() async {
        let tower = FakeTower()
        tower.seedPriorMatchRun()
        let model = await model(tower)
        model.reload()
        await settle(model)

        model.runMatching()
        await settle(model)
        let matchCalls = tower.calls.filter { $0.path.hasSuffix("/match") }
        #expect(matchCalls.count == 1)
        let progressQueries = tower.calls.filter { $0.path.hasSuffix("/match_webhooks") }.compactMap(\.query)
        #expect(progressQueries.first == "since_sequence=0")
        #expect(progressQueries.dropFirst().allSatisfy { $0 == "since_sequence=7" || $0 == "since_sequence=9" })
        #expect(model.job == .none)
        #expect(model.message == nil)
    }

    @Test func describingFootageReportsProgressThenSaysToRematch() async {
        let tower = FakeTower()
        let model = await model(tower)
        model.recaption()
        await settle(model)
        #expect(model.job == .none)
        #expect(model.message == "Footage described. Run matching to update the board.")
        #expect(tower.calls.contains { $0.path.hasSuffix("/recaption_webhooks") && $0.query == "since_sequence=3" })
    }

    @Test func describingWhenEverythingIsDescribedSaysSo() async {
        let tower = FakeTower()
        tower.setRecaptionStatus("nothing_to_do")
        let model = await model(tower)
        model.recaption()
        await settle(model)
        #expect(model.job == .none)
        #expect(model.message == "Every file is already described.")
    }

    @Test func aCorrectionReplacesTheBoardWithTheTowersAnswer() async throws {
        let tower = FakeTower()
        let model = await model(tower)
        model.reload()
        await settle(model)

        model.assign("f-2", startMs: 0, endMs: 2000, to: "b-1")
        await settle(model)
        #expect(model.board?.beats.first?.matches.first?.overrideId == "o-1")
    }

    @Test func anUnlinkedProjectAsksNothing() async {
        let tower = FakeTower()
        let model = await model(tower, linked: false)
        model.reload()
        model.runMatching()
        model.recaption()
        #expect(tower.calls.isEmpty)
        #expect(model.status == .idle)
    }

    @Test func refreshShowsWhatWouldChangeBeforeApplying() async throws {
        let tower = FakeTower()
        let model = await model(tower)
        model.reload()
        await settle(model)

        model.previewRefresh()
        await settle(model)
        guard case .review(let report, nil) = model.refresh else {
            Issue.record("expected a review, got \(model.refresh)")
            return
        }
        #expect(report.changed == 1 && report.added == 1 && report.removed == 1)
        #expect(report.removedBeats.first?.overridesLost == 1)
        let preview = try #require(tower.calls.last { $0.path.hasSuffix("/refresh") })
        #expect((try? JSONSerialization.jsonObject(with: preview.body ?? Data())) as? [String: Bool] == ["dry_run": true])

        model.applyRefresh()
        await settle(model)
        #expect(model.refresh == .none)
        #expect(model.message == "2 beats changed. Run matching to match them again.")
        #expect(tower.calls.filter { $0.path.hasSuffix("/refresh") }.count == 2)
        #expect(tower.calls.last?.path == "/api/v1/scripts/s-1/board")
    }

    // A script imported from a file can only be refreshed with the revised file.
    @Test func aFileSourcedScriptAsksForTheRevisedFile() async throws {
        let tower = FakeTower()
        tower.makeFileSourced()
        let model = await model(tower)
        model.reload()
        await settle(model)

        model.previewRefresh()
        await settle(model)
        #expect(model.refresh == .needsFile)

        let dir = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let revised = dir.appendingPathComponent("script-v4.csv")
        try Data("#,Video\n1,Close on denim\n".utf8).write(to: revised)
        model.previewRefresh(file: revised)
        await settle(model)
        guard case .review(_, let file?) = model.refresh else {
            Issue.record("expected a review of the file, got \(model.refresh)")
            return
        }
        #expect(file == revised)
    }

    @Test func aBeatTheScriptChangedReadsAsUnmatched() async throws {
        let data = FakeTower.json(FakeTower.board())
        var object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        var beats = try #require(object["beats"] as? [[String: Any]])
        beats[0]["matched"] = false
        object["beats"] = beats
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let board = try decoder.decode(NUEDITBackendClient.Board.self, from: FakeTower.json(object))
        #expect(board.beats[0].matched == false)
        #expect(board.beats[1].matched == nil)
    }
}
