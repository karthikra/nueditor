import Foundation

// add_markers, remove_markers.
extension ToolExecutor {
    static let maxMarkersPerCall = 1_000
    static let maxMarkerTextLength = 2_000

    func addMarkers(_ editor: EditorViewModel, _ args: [String: Any]) throws -> ToolResult {
        try validateUnknownKeys(args, allowed: ["timelineId", "entries"], path: "add_markers")
        let timeline = try markerTimeline(editor, args, path: "add_markers")
        guard let entries = args["entries"] as? [[String: Any]], !entries.isEmpty else {
            throw ToolError("add_markers: entries must be a non-empty array of {frame, durationFrames?, kind?, text?}.")
        }
        guard entries.count <= Self.maxMarkersPerCall else {
            throw ToolError("add_markers: at most \(Self.maxMarkersPerCall) markers per call.")
        }
        // Validate every entry before adding any, so a bad one leaves the timeline untouched.
        let markers = try entries.enumerated().map { index, entry in
            try Self.marker(from: entry, path: "add_markers.entries[\(index)]")
        }
        let added = editor.addMarkers(markers, toTimeline: timeline.id)
        let payload: [String: Any] = [
            "timelineId": timeline.id,
            "added": added.map(Self.markerJSON),
        ]
        return .ok(Self.jsonString(payload) ?? "{}")
    }

    func removeMarkers(_ editor: EditorViewModel, _ args: [String: Any]) throws -> ToolResult {
        try validateUnknownKeys(args, allowed: ["timelineId", "ids", "kinds", "all"], path: "remove_markers")
        let timeline = try markerTimeline(editor, args, path: "remove_markers")
        let ids = args["ids"] as? [String]
        let kindNames = args["kinds"] as? [String]
        let all = args["all"] as? Bool ?? false
        guard [ids != nil, kindNames != nil, all].count(where: { $0 }) == 1 else {
            throw ToolError("remove_markers: pass exactly one of ids, kinds, or all: true.")
        }
        var targets = Set<String>()
        if let ids {
            targets = Set(ids)
        } else if let kindNames {
            let kinds = try Set(kindNames.map { name -> TimelineMarker.Kind in
                guard let kind = TimelineMarker.Kind(rawValue: name) else {
                    throw ToolError("remove_markers: unknown kind '\(name)'. Valid: \(Self.markerKindNames).")
                }
                return kind
            })
            targets = Set(timeline.markers.filter { kinds.contains($0.kind) }.map(\.id))
        } else {
            targets = Set(timeline.markers.map(\.id))
        }
        let removed = editor.removeMarkers(ids: targets, fromTimeline: timeline.id)
        var payload: [String: Any] = [
            "timelineId": timeline.id,
            "removed": removed.map(\.id),
            "changed": !removed.isEmpty,
        ]
        if let ids {
            let missing = Set(ids).subtracting(removed.map(\.id))
            if !missing.isEmpty { payload["notFound"] = missing.sorted() }
        }
        return .ok(Self.jsonString(payload) ?? "{}")
    }

    private func markerTimeline(_ editor: EditorViewModel, _ args: [String: Any], path: String) throws -> Timeline {
        guard let id = args.string("timelineId") else { return editor.timeline }
        guard let timeline = editor.timeline(for: id) else {
            throw ToolError("\(path): no timeline with id '\(id)'. get_media lists the project's timelines.")
        }
        return timeline
    }

    static var markerKindNames: String { TimelineMarker.Kind.allCases.map(\.rawValue).joined(separator: ", ") }

    static func marker(from entry: [String: Any], path: String) throws -> TimelineMarker {
        let allowed: Set<String> = ["frame", "durationFrames", "kind", "text"]
        if let unknown = entry.keys.first(where: { !allowed.contains($0) }) {
            throw ToolError("\(path): unknown key '\(unknown)'.")
        }
        guard let frame = entry["frame"] as? Int, frame >= 0 else {
            throw ToolError("\(path).frame must be a non-negative integer (project frames).")
        }
        let duration = entry["durationFrames"] as? Int ?? 0
        guard entry["durationFrames"] == nil || entry["durationFrames"] is Int, duration >= 0 else {
            throw ToolError("\(path).durationFrames must be a non-negative integer.")
        }
        guard !frame.addingReportingOverflow(duration).overflow else {
            throw ToolError("\(path): frame + durationFrames is out of range.")
        }
        var kind = TimelineMarker.Kind.note
        if let name = entry["kind"] {
            guard let raw = name as? String, let parsed = TimelineMarker.Kind(rawValue: raw) else {
                throw ToolError("\(path).kind must be one of: \(markerKindNames).")
            }
            kind = parsed
        }
        let text = entry["text"] as? String ?? ""
        guard entry["text"] == nil || entry["text"] is String, text.count <= maxMarkerTextLength else {
            throw ToolError("\(path).text must be a string of at most \(maxMarkerTextLength) characters.")
        }
        return TimelineMarker(frame: frame, durationFrames: duration, kind: kind, text: text)
    }

    static func markerJSON(_ marker: TimelineMarker) -> [String: Any] {
        ["id": marker.id, "frame": marker.frame, "durationFrames": marker.durationFrames,
         "kind": marker.kind.rawValue, "text": marker.text]
    }
}
