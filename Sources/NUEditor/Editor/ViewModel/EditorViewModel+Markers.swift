import Foundation

// Timeline markers: one undoable action per add or remove, whichever timeline they're on.
extension EditorViewModel {

    /// Adds markers to a timeline; returns the markers as stored, or none if the timeline is gone.
    @discardableResult
    func addMarkers(_ markers: [TimelineMarker], toTimeline timelineId: String) -> [TimelineMarker] {
        guard !markers.isEmpty, let index = timelines.firstIndex(where: { $0.id == timelineId }) else { return [] }
        timelines[index].markers = (timelines[index].markers + markers).sorted { ($0.frame, $0.id) < ($1.frame, $1.id) }
        let ids = Set(markers.map(\.id))
        undo.register(markers.count == 1 ? "Add Marker" : "Add Markers", withTarget: self) { vm in
            vm.removeMarkers(ids: ids, fromTimeline: timelineId)
        }
        onProjectCheckpointRequired?()
        return markers
    }

    /// Removes the markers with these ids; returns what was removed. Unknown ids are ignored.
    @discardableResult
    func removeMarkers(ids: Set<String>, fromTimeline timelineId: String) -> [TimelineMarker] {
        guard let index = timelines.firstIndex(where: { $0.id == timelineId }) else { return [] }
        let removed = timelines[index].markers.filter { ids.contains($0.id) }
        guard !removed.isEmpty else { return [] }
        timelines[index].markers.removeAll { ids.contains($0.id) }
        undo.register(removed.count == 1 ? "Remove Marker" : "Remove Markers", withTarget: self) { vm in
            vm.addMarkers(removed, toTimeline: timelineId)
        }
        onProjectCheckpointRequired?()
        return removed
    }
}
