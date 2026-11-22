import Foundation
import Synchronization
import Testing
@testable import NUEditor

private enum TowerScripts {
    static func response(dryRun: Bool, scripts: Int = 1, scriptId: String? = nil) -> Data {
        let script: [String: Any] = [
            "script_id": scriptId ?? NSNull(), "title": "LEVI'S 501 — 30s TVC v3",
            "source": ["kind": "google_sheet", "url": "https://docs.google.com/spreadsheets/d/x"],
            "header_row": 4,
            "columns": [["header": "#", "role": "label"], ["header": "Video", "role": "visual"],
                        ["header": "VO", "role": "audio"], ["header": "Camera", "role": NSNull()]],
            "unmapped": ["Props"],
            "beats": [[
                "order": 1, "label": "1", "scene": "", "visual": "Close on denim", "audio": "Made to last.",
                "on_screen_text": "", "sound": "", "notes": "", "duration_seconds": 3.0, "start_seconds": 0.0,
                "script_gap": false, "source_row": 5,
            ]],
            "beat_count": 9, "total_seconds": 30.0, "warnings": ["Ignored column: Props."],
        ]
        let body: [String: Any] = ["dry_run": dryRun, "warnings": [], "scripts": Array(repeating: script, count: scripts)]
        return (try? JSONSerialization.data(withJSONObject: body)) ?? Data()
    }

    static func client(_ handler: @escaping StubHTTP.Handler) async -> (NUEDITBackendClient, String) {
        let host = StubHTTP.host(handler)
        let client = NUEDITBackendClient(session: StubHTTP.session())
        await client.use(NUEDITBackendSettings(baseURL: URL(string: "http://\(host)"), agentKey: .value("k")))
        return (client, host)
    }
}

@Suite("Script import — client")
struct ScriptImportClientTests {

    @Test func aLinkIsSentAsJSONWithTheMappingAndTheResponseDecodes() async throws {
        let (client, host) = await TowerScripts.client { _ in (200, TowerScripts.response(dryRun: true)) }
        let pinned: [NUEDITBackendClient.ScriptColumnRole: String?] = [.visual: "Video", .notes: nil]
        let response = try await client.importScript(
            projectId: "p-1", source: .link("https://docs.google.com/spreadsheets/d/x"), mapping: pinned, dryRun: true
        )

        let request = try #require(StubHTTP.requests(to: host).first)
        #expect(request.url.path == "/api/v1/projects/p-1/scripts/import")
        #expect(request.headers["Content-Type"] == "application/json")
        let body = try #require(try JSONSerialization.jsonObject(with: request.body ?? Data()) as? [String: Any])
        #expect((body["source"] as? [String: String])?["url"] == "https://docs.google.com/spreadsheets/d/x")
        #expect(body["dry_run"] as? Bool == true)
        let mapping = try #require(body["mapping"] as? [String: Any])
        #expect(mapping["visual"] as? String == "Video")
        #expect(mapping["notes"] is NSNull)

        let script = try #require(response.scripts.first)
        #expect(response.dryRun)
        #expect(script.scriptId == nil)
        #expect(script.headerRow == 4 && script.beatCount == 9 && script.totalSeconds == 30)
        let roles: [NUEDITBackendClient.ScriptColumnRole?] = [.label, .visual, .audio, nil]
        #expect(script.columns.map(\.role) == roles)
        #expect(script.beats.first?.onScreenText == "")
        #expect(script.beats.first?.durationSeconds == 3)
    }

    @Test func aFileIsUploadedAsMultipartWithItsFields() async throws {
        let dir = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let csv = dir.appendingPathComponent("script.csv")
        try Data("#,Video,VO\n1,Close on denim,Made to last.\n".utf8).write(to: csv)
        let (client, host) = await TowerScripts.client { _ in (201, TowerScripts.response(dryRun: false, scriptId: "s-1")) }

        let response = try await client.importScript(
            projectId: "p-1", source: .file(csv), mapping: [.visual: "Video"], dryRun: false, stagingDirectory: dir
        )
        let request = try #require(StubHTTP.requests(to: host).first)
        let body = String(decoding: request.body ?? Data(), as: UTF8.self)
        #expect(request.headers["Content-Type"]?.hasPrefix("multipart/form-data; boundary=") == true)
        #expect(body.contains(#"name="file"; filename="script.csv""#))
        #expect(body.contains("Content-Type: text/csv"))
        #expect(body.contains("1,Close on denim,Made to last."))
        #expect(body.contains(#"name="dry_run""#) && body.contains("false"))
        #expect(body.contains(#"{"visual":"Video"}"#))
        #expect(response.scripts.first?.scriptId == "s-1")
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path) == ["script.csv"])
    }

    // The tower's message tells the user how to share the sheet; it must reach them as written.
    @Test func aTowerRefusalCarriesItsCodeAndMessage() async throws {
        let detail = #"{"detail":{"code":"not_shared","message":"Share the sheet with Anyone with the link."}}"#
        let (client, _) = await TowerScripts.client { _ in (422, Data(detail.utf8)) }
        await #expect {
            _ = try await client.importScript(projectId: "p-1", source: .link("https://docs.google.com/x"), dryRun: true)
        } throws: { error in
            guard case BackendError.api(422, "not_shared", "Share the sheet with Anyone with the link.") = error else { return false }
            return true
        }
    }

    @Test func anUnsupportedFileIsRefusedBeforeAnythingIsSent() async throws {
        let (client, host) = await TowerScripts.client { _ in (200, Data()) }
        await #expect(throws: BackendError.self) {
            _ = try await client.importScript(projectId: "p-1", source: .file(URL(fileURLWithPath: "/tmp/script.pdf")), dryRun: true)
        }
        #expect(StubHTTP.requests(to: host).isEmpty)
    }
}

@Suite("Script import — sheet model")
@MainActor
struct ScriptImportModelTests {

    private final class Calls: Sendable {
        private let bodies = Mutex<[Data]>([])
        func record(_ data: Data?) { bodies.withLock { $0.append(data ?? Data()) } }
        var all: [[String: Any]] {
            bodies.withLock { $0 }.map { (try? JSONSerialization.jsonObject(with: $0)) as? [String: Any] ?? [:] }
        }
    }

    private func model(status: Int = 200, body: @escaping @Sendable (Bool) -> Data = { TowerScripts.response(dryRun: $0) }) async -> (ScriptImportModel, Calls) {
        let calls = Calls()
        let (client, _) = await TowerScripts.client { request in
            calls.record(request.httpBody)
            let dryRun = ((try? JSONSerialization.jsonObject(with: request.httpBody ?? Data())) as? [String: Any])?["dry_run"] as? Bool ?? true
            return (status, body(dryRun))
        }
        let model = ScriptImportModel(projectId: "p-1", client: client)
        model.linkText = "https://docs.google.com/spreadsheets/d/x"
        return (model, calls)
    }

    private func settle(_ model: ScriptImportModel) async {
        await model.pendingWork?.value
    }

    @Test func detectingShowsTheTowersReadingForReview() async {
        let (model, calls) = await model()
        model.detect()
        await settle(model)
        #expect(model.phase == .review)
        #expect(model.reviewedScript?.beatCount == 9)
        #expect(model.isPreviewCurrent)
        #expect(calls.all.first?["dry_run"] as? Bool == true)
    }

    // Import must store exactly what the user last saw.
    @Test func changingAColumnHoldsImportUntilThePreviewIsUpdated() async {
        let (model, calls) = await model()
        model.detect()
        await settle(model)

        model.assign(.notes, toColumn: "Camera")
        #expect(!model.isPreviewCurrent)
        #expect(model.pendingRole(ofColumn: "Camera") == .notes)
        model.importScripts()
        #expect(calls.all.count == 1)

        model.detect()
        await settle(model)
        #expect((calls.all.last?["mapping"] as? [String: Any])?["notes"] as? String == "Camera")
        model.importScripts()
        await settle(model)
        #expect(model.phase == .done)
        #expect(calls.all.last?["dry_run"] as? Bool == false)
    }

    @Test func ignoringADetectedColumnUnmapsItsRole() async {
        let (model, _) = await model()
        model.detect()
        await settle(model)
        model.assign(nil, toColumn: "VO")
        #expect(model.pendingRole(ofColumn: "VO") == nil)
        #expect(model.mapping[.audio] == .some(nil))
    }

    @Test func aTowerRefusalIsShownAsTheTowerWroteIt() async {
        let detail = #"{"detail":{"code":"not_shared","message":"Share the sheet with Anyone with the link."}}"#
        let (model, _) = await model(status: 422, body: { _ in Data(detail.utf8) })
        model.detect()
        await settle(model)
        #expect(model.phase == .failed("Share the sheet with Anyone with the link."))
    }

    @Test func anUnlinkedProjectSendsNothing() async {
        let model = ScriptImportModel(projectId: nil)
        model.linkText = "https://docs.google.com/x"
        model.detect()
        #expect(model.phase == .source)
    }
}
