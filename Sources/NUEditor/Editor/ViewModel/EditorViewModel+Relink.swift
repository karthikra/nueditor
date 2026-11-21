import Foundation

// Reconnect offline media by repointing assets at a relocated source file or folder.
extension EditorViewModel {

    /// Repoint a single asset at a new source file, re-validate, and rebuild.
    func relinkAsset(id: String, to newURL: URL, notify: Bool = true) {
        guard let asset = mediaAssets.first(where: { $0.id == id }) else { return }
        if let newType = ClipType(fileExtension: newURL.pathExtension.lowercased()), newType != asset.type {
            mediaPanelToast = "Can't relink — \"\(newURL.lastPathComponent)\" is \(newType.trackLabel.lowercased()), not \(asset.type.trackLabel.lowercased())."
            return
        }
        applyRelink(id: id, to: newURL)
        if notify { notifyTimelineChanged() }
    }

    /// Relinks every offline asset to a file under `folder` (recursive): by content for identified
    /// footage, by filename otherwise. Scanning and hashing run off the main actor.
    @discardableResult
    func relinkOfflineAssets(fromFolder folder: URL) async -> (relinked: Int, total: Int) {
        let offline = mediaAssets.filter { isMediaOffline($0.id) }
        guard !offline.isEmpty else { return (0, 0) }
        let clips = offline.map {
            FolderRelinkMatcher.OfflineClip(id: $0.id, filename: $0.url.lastPathComponent, identity: $0.footageIdentity)
        }
        let before = Dictionary(uniqueKeysWithValues: offline.map { ($0.id, $0.url) })
        let files = await FolderRelinkMatcher.scan(folder)
        let matches = await FolderRelinkMatcher.match(clips, in: files)

        var relinked = 0
        for (id, url) in matches {
            // The library may have moved on while the folder was searched.
            guard let asset = mediaAssets.first(where: { $0.id == id }), asset.url == before[id], isMediaOffline(id) else { continue }
            relinkAsset(id: id, to: url, notify: false)
            if asset.footageIdentity != nil { ingest.cancel(assetId: id) }
            relinked += 1
        }
        if relinked > 0 {
            notifyTimelineChanged()
            ingest.registerPendingFootage()
        }
        Log.project.info("relink from folder relinked=\(relinked) of offline=\(offline.count) files=\(files.count)")
        return (relinked, offline.count)
    }

    private func applyRelink(id: String, to newURL: URL) {
        guard let i = mediaAssets.firstIndex(where: { $0.id == id }) else { return }
        mediaAssets[i].url = newURL
        denoiseFailed.remove(id)
        denoiseBaked.remove(id)
        mediaVisualCache.invalidate(id)
        speakerAssignments.removeValue(forKey: id)
        if let j = mediaManifest.entries.firstIndex(where: { $0.id == id }) {
            mediaManifest.entries[j].source = mediaAssets[i].toManifestEntry(projectURL: projectURL).source
        }
        let asset = mediaAssets[i]
        Task { await finalizeImportedAsset(asset) }
    }
}
