import Foundation
import Testing
@testable import NUEditor

@Suite("EdgeRegistrar — what leaves this machine")
struct EdgeRegistrarTests {

    private func scratch() throws -> URL {
        let dir = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func identity(checksum: String = "abc123") -> FootageIdentity {
        FootageIdentity(
            checksum: checksum, fileSizeBytes: 500_000_000, codec: "hvc1",
            volumeUUID: "VOL-1", volumeLabel: "CARD", volumeRelativePath: "DCIM/A001.mov",
            mountPoint: "/Volumes/CARD"
        )
    }

    private func request(derivatives: [ProxyKind: URL]) -> EdgeRegistrar.Request {
        EdgeRegistrar.Request(
            projectId: "p-1", filename: "A001.mov", durationMilliseconds: 4200,
            identity: identity(), frameRate: 23.976, width: 3840, height: 2160,
            hasAudio: true, derivatives: derivatives
        )
    }

    // The camera original is never a derivative — the whole reduction depends on it.
    @Test func onlyDerivativesAreEverUploaded() {
        #expect(!EdgeRegistrar.uploadedKinds.isEmpty)
        for kind in EdgeRegistrar.uploadedKinds {
            #expect(kind.backendDerivative != nil, "\(kind) has no tower slot")
        }
        #expect(EdgeRegistrar.uploadedKinds.contains(.vlm))
        #expect(EdgeRegistrar.uploadedKinds.contains(.audio))
    }

    // With no tower address, ingest is finished work sitting locally — not a failure to report.
    @Test func anUnconfiguredTowerSkipsRatherThanFails() async throws {
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let proxy = dir.appendingPathComponent("vlm.mp4")
        try Data("proxy".utf8).write(to: proxy)

        let client = NUEDITBackendClient()
        await client.use(NUEDITBackendSettings(baseURL: nil, token: nil))
        let outcome = await EdgeRegistrar.register(request(derivatives: [.vlm: proxy]), client: client, stagingDirectory: dir)
        guard case .skipped = outcome else {
            Issue.record("expected skipped, got \(outcome)")
            return
        }
    }

    @Test func nothingIsSentWithoutADerivativeTheTowerAccepts() async throws {
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let client = NUEDITBackendClient()
        await client.use(NUEDITBackendSettings(baseURL: URL(string: "http://127.0.0.1:1"), token: nil))
        // A preview proxy alone is not enough: the tower requires vlm_proxy or audio.
        let preview = dir.appendingPathComponent("preview.mp4")
        try Data("preview".utf8).write(to: preview)
        let outcome = await EdgeRegistrar.register(request(derivatives: [.preview: preview]), client: client, stagingDirectory: dir)
        #expect(outcome == .skipped("No derivative to send yet."))
    }

    @Test func aMissingProxyFileIsNotOffered() async throws {
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let client = NUEDITBackendClient()
        await client.use(NUEDITBackendSettings(baseURL: URL(string: "http://127.0.0.1:1"), token: nil))
        let gone = dir.appendingPathComponent("gone.mp4")
        let outcome = await EdgeRegistrar.register(request(derivatives: [.vlm: gone]), client: client, stagingDirectory: dir)
        #expect(outcome == .skipped("No derivative to send yet."))
    }

    // An unreachable tower must leave the footage re-registerable, not mark it failed.
    @Test func anUnreachableTowerSkips() async throws {
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let proxy = dir.appendingPathComponent("vlm.mp4")
        try Data("proxy".utf8).write(to: proxy)
        let client = NUEDITBackendClient()
        // Port 1 refuses immediately: a transport failure, not an API rejection.
        await client.use(NUEDITBackendSettings(baseURL: URL(string: "http://127.0.0.1:1"), token: nil))
        let outcome = await EdgeRegistrar.register(request(derivatives: [.vlm: proxy]), client: client, stagingDirectory: dir)
        guard case .skipped = outcome else {
            Issue.record("an unreachable tower must skip, got \(outcome)")
            return
        }
        // And it left nothing staged behind.
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        #expect(leftovers == ["vlm.mp4"], "staged upload body survived: \(leftovers)")
    }
}

@Suite("tower_link")
@MainActor
struct TowerLinkTests {

    @Test func reportsUnlinkedByDefault() async throws {
        let h = ToolHarness(timeline: Fixtures.timeline())
        let payload = try await h.runOK("tower_link") as? [String: Any]
        #expect(payload?["linked"] as? Bool == false)
        #expect(payload?["projectId"] == nil)
        #expect(payload?["note"] != nil)
    }

    @Test func linksAndPersistsToTheProject() async throws {
        let h = ToolHarness(timeline: Fixtures.timeline())
        let payload = try await h.runOK("tower_link", args: ["projectId": "11111111-2222-3333-4444-555555555555"]) as? [String: Any]
        #expect(payload?["linked"] as? Bool == true)
        #expect(payload?["changed"] as? Bool == true)
        #expect(h.editor.towerProjectId == "11111111-2222-3333-4444-555555555555")
        #expect(h.editor.projectFileSnapshot().towerProjectId == "11111111-2222-3333-4444-555555555555")
    }

    // Re-linking to the same id is a no-op, and says so rather than reporting a change.
    @Test func relinkingTheSameProjectReportsNoChange() async throws {
        let h = ToolHarness(timeline: Fixtures.timeline())
        _ = try await h.runOK("tower_link", args: ["projectId": "p-1"])
        let payload = try await h.runOK("tower_link", args: ["projectId": "p-1"]) as? [String: Any]
        #expect(payload?["changed"] as? Bool == false)
        #expect(payload?["linked"] as? Bool == true)
    }

    @Test func clearUnlinks() async throws {
        let h = ToolHarness(timeline: Fixtures.timeline())
        _ = try await h.runOK("tower_link", args: ["projectId": "p-1"])
        let payload = try await h.runOK("tower_link", args: ["clear": true]) as? [String: Any]
        #expect(payload?["linked"] as? Bool == false)
        #expect(h.editor.towerProjectId == nil)
    }

    @Test func rejectsContradictoryArguments() async {
        let h = ToolHarness(timeline: Fixtures.timeline())
        let result = await h.runRaw("tower_link", args: ["projectId": "p-1", "clear": true])
        #expect(result.isError)
    }

    @Test func rejectsAnEmptyProjectId() async {
        let h = ToolHarness(timeline: Fixtures.timeline())
        #expect(await h.runRaw("tower_link", args: ["projectId": "  "]).isError)
    }

    @Test func rejectsUnknownArguments() async {
        let h = ToolHarness(timeline: Fixtures.timeline())
        #expect(await h.runRaw("tower_link", args: ["project": "p-1"]).isError)
    }

    // The receipt has to say what actually reached the tower, not just that a link exists.
    @Test func reportsTheLibrarysIngestState() async throws {
        let h = ToolHarness(timeline: Fixtures.timeline())
        let asset = MediaAsset(url: URL(fileURLWithPath: "/Volumes/CARD/A001.mov"), type: .video, name: "A001")
        asset.footageIdentity = FootageIdentity(checksum: "abc", fileSizeBytes: 10)
        asset.ingestStatus = .local
        h.editor.mediaAssets.append(asset)

        let payload = try await h.runOK("tower_link") as? [String: Any]
        let footage = payload?["footage"] as? [String: Any]
        #expect(footage?["eligible"] as? Int == 1)
        #expect(footage?["identified"] as? Int == 1)
        #expect(footage?["registered"] as? Int == 0)
    }

    // "Registered" is not "safe": the receipt says separately whether each original has a copy.
    @Test func reportsWhetherOriginalsAreArchived() async throws {
        let h = ToolHarness(timeline: Fixtures.timeline())
        for (name, uri) in [("A001", "s3://nuedit-media/p/f-a/A001.mov"), ("A002", nil)] {
            let asset = MediaAsset(url: URL(fileURLWithPath: "/Volumes/CARD/\(name).mov"), type: .video, name: name)
            asset.footageIdentity = FootageIdentity(checksum: name, fileSizeBytes: 10)
            asset.footageId = "f-\(name)"
            asset.originalArchiveURI = uri
            h.editor.mediaAssets.append(asset)
        }

        let payload = try await h.runOK("tower_link") as? [String: Any]
        let originals = payload?["originals"] as? [String: Any]
        #expect(originals?["archived"] as? Int == 1)
        #expect(originals?["waiting"] as? Int == 1)
        #expect(originals?["failed"] as? Int == 0)
    }
}
