import Foundation
import Testing
@testable import NUEditor

@Suite("Timeline markers — add_markers / remove_markers")
@MainActor
struct TimelineMarkerTests {

    private func harness() -> (ToolHarness, UndoManager) {
        let h = ToolHarness()
        let undo = UndoManager()
        undo.groupsByEvent = false
        h.editor.undo.attach(undo)
        return (h, undo)
    }

    private func add(_ h: ToolHarness, _ entries: [[String: Any]], timelineId: String? = nil) async throws -> [[String: Any]] {
        var args: [String: Any] = ["entries": entries]
        if let timelineId { args["timelineId"] = timelineId }
        let json = try await h.runOK("add_markers", args: args) as? [String: Any]
        return json?["added"] as? [[String: Any]] ?? []
    }

    @Test func markersAreAddedSortedAndReadBackThroughGetTimeline() async throws {
        let (h, _) = harness()
        let added = try await add(h, [
            ["frame": 240, "kind": "missing", "text": "Beat 2 — rider on rooftop"],
            ["frame": 48, "durationFrames": 72, "kind": "low_confidence", "text": "Beat 1"],
        ])
        #expect(added.count == 2)
        #expect(h.editor.timeline.markers.map(\.frame) == [48, 240])
        #expect(h.editor.timeline.markers.map(\.kind) == [.lowConfidence, .missing])

        let timeline = try await h.runOK("get_timeline") as? [String: Any]
        let markers = timeline?["markers"] as? [[String: Any]]
        #expect(markers?.map { $0["kind"] as? String } == ["low_confidence", "missing"])
        #expect(markers?.first?["durationFrames"] as? Int == 72)
    }

    // One bad entry must not leave the others behind.
    @Test(arguments: [
        #"{"frame": -1}"#,
        #"{"frame": 10, "durationFrames": -5}"#,
        #"{"frame": 10, "kind": "urgent"}"#,
        #"{"frame": 10, "colour": "red"}"#,
        #"{"frame": 2.5}"#,
        #"{"frame": 9223372036854775807, "durationFrames": 1}"#,
    ])
    func anInvalidEntryRejectsTheWholeCall(badJSON: String) async throws {
        let bad = try #require(try JSONSerialization.jsonObject(with: Data(badJSON.utf8)) as? [String: Any])
        let (h, _) = harness()
        let result = await h.runRaw("add_markers", args: ["entries": [["frame": 0, "text": "fine"], bad]])
        #expect(result.isError)
        #expect(h.editor.timeline.markers.isEmpty)
    }

    @Test func oneCallUndoesAndRedoesAsOneAction() async throws {
        let (h, undo) = harness()
        _ = try await add(h, [["frame": 0], ["frame": 10], ["frame": 20]])
        #expect(undo.undoActionName == "Add Markers")
        undo.undo()
        #expect(h.editor.timeline.markers.isEmpty)
        undo.redo()
        #expect(h.editor.timeline.markers.count == 3)
    }

    @Test func removingByKindLeavesTheRest() async throws {
        let (h, undo) = harness()
        _ = try await add(h, [["frame": 0, "kind": "missing"], ["frame": 10, "kind": "note"], ["frame": 20, "kind": "missing"]])
        let json = try await h.runOK("remove_markers", args: ["kinds": ["missing"]]) as? [String: Any]
        #expect((json?["removed"] as? [String])?.count == 2)
        #expect(h.editor.timeline.markers.map(\.kind) == [.note])
        undo.undo()
        #expect(h.editor.timeline.markers.count == 3)
    }

    @Test func removingNothingSaysSoAndAddsNoUndoStep() async throws {
        let (h, undo) = harness()
        _ = try await add(h, [["frame": 0]])
        let json = try await h.runOK("remove_markers", args: ["ids": ["no-such-marker"]]) as? [String: Any]
        #expect(json?["changed"] as? Bool == false)
        #expect(json?["notFound"] as? [String] == ["no-such-marker"])
        #expect(undo.undoActionName == "Add Marker")
    }

    @Test func removeNeedsExactlyOneSelector() async throws {
        let (h, _) = harness()
        #expect(await h.runRaw("remove_markers", args: [:]).isError)
        #expect(await h.runRaw("remove_markers", args: ["all": true, "kinds": ["note"]]).isError)
    }

    // NUEDIT's rough cut marks a timeline it just created, which may not be the active one.
    @Test func markersCanTargetATimelineThatIsntActive() async throws {
        let (h, _) = harness()
        let other = h.editor.createTimeline(name: "Rough cut", activate: false)
        _ = try await add(h, [["frame": 5, "kind": "script_gap"]], timelineId: other)
        #expect(h.editor.timeline.markers.isEmpty)
        #expect(h.editor.timeline(for: other)?.markers.map(\.kind) == [.scriptGap])
        #expect(await h.runRaw("add_markers", args: ["timelineId": "nope", "entries": [["frame": 0]]]).isError)
    }

    @Test func projectsSavedBeforeMarkersStillOpen() throws {
        var timeline = Fixtures.timeline()
        timeline.markers = [TimelineMarker(frame: 1)]
        var object = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(timeline)) as? [String: Any])
        object.removeValue(forKey: "markers")
        let decoded = try JSONDecoder().decode(Timeline.self, from: JSONSerialization.data(withJSONObject: object))
        #expect(decoded.markers.isEmpty)
    }

    @Test func aKindFromANewerBuildReadsAsANote() throws {
        let json = #"{"id":"m","frame":3,"durationFrames":0,"kind":"chapter","text":"x"}"#
        let marker = try JSONDecoder().decode(TimelineMarker.self, from: Data(json.utf8))
        #expect(marker.kind == .note)
    }

    @Test func markersSurviveSaveAndLoad() throws {
        var timeline = Fixtures.timeline()
        timeline.markers = [TimelineMarker(frame: 12, durationFrames: 24, kind: .alternate, text: "Take 3")]
        let decoded = try JSONDecoder().decode(Timeline.self, from: JSONEncoder().encode(timeline))
        #expect(decoded.markers == timeline.markers)
    }
}
