import AppKit

// Edge ingest Stage 4: camera originals follow their drive, not their path.
extension EditorViewModel {

    /// Reconnects offline originals that have a content identity to wherever their bytes are mounted
    /// now. Coalesced: a request while a pass runs schedules exactly one more pass.
    func relinkOfflineOriginals() {
        guard identityRelinkTask == nil else {
            identityRelinkRequested = true
            return
        }
        identityRelinkTask = Task { @MainActor [weak self] in
            repeat {
                self?.identityRelinkRequested = false
                await self?.relinkOfflineOriginalsPass()
            } while self?.identityRelinkRequested == true && !Task.isCancelled
            self?.identityRelinkTask = nil
        }
    }

    private func relinkOfflineOriginalsPass() async {
        let candidates = mediaAssets.compactMap { asset -> (id: String, url: URL, identity: FootageIdentity)? in
            guard missingMediaRefs.contains(asset.id) || offlineMediaRefs.contains(asset.id),
                  let identity = asset.footageIdentity else { return nil }
            return (asset.id, asset.url, identity)
        }
        guard !candidates.isEmpty else { return }

        let volumes = await OriginalLocator.mountedVolumes()
        var found: [(id: String, from: URL, to: URL, checksum: String)] = []
        for candidate in candidates {
            guard !Task.isCancelled else { return }
            if let url = await OriginalLocator.locate(candidate.identity, on: volumes) {
                found.append((candidate.id, candidate.url, url, candidate.identity.checksum))
            }
        }

        var relinked: [String] = []
        for match in found {
            // The library may have moved on while the drives were searched.
            guard let asset = mediaAssets.first(where: { $0.id == match.id }), asset.url == match.from,
                  asset.footageIdentity?.checksum == match.checksum,
                  missingMediaRefs.contains(match.id) || offlineMediaRefs.contains(match.id) else { continue }
            relinkAsset(id: match.id, to: match.to, notify: false)
            relinked.append(match.id)
        }
        guard !relinked.isEmpty else { return }
        notifyTimelineChanged()
        Log.project.info("relink by identity reconnected=\(relinked.count) of offline=\(candidates.count)")
        mediaPanelToast = MediaPanelToast(
            message: "Reconnected \(relinked.count) clip\(relinked.count == 1 ? "" : "s") from \(Self.volumeNames(for: relinked, in: self)).",
            kind: .success
        )
        // An archive that stopped because its drive was gone resumes from the new location.
        for id in relinked { ingest.cancel(assetId: id) }
        ingest.registerPendingFootage()
    }

    private static func volumeNames(for ids: [String], in editor: EditorViewModel) -> String {
        let names = Set(ids.compactMap { id in editor.mediaAssets.first { $0.id == id }?.footageIdentity?.volumeLabel })
        return names.isEmpty ? "their drive" : names.sorted().joined(separator: ", ")
    }

    /// Originals on a drive that just went away are offline now, before playback trips over them.
    func markOriginalsOffline(onVolumeAt volumeURL: URL) {
        let prefix = volumeURL.standardizedFileURL.path.hasSuffix("/")
            ? volumeURL.standardizedFileURL.path : volumeURL.standardizedFileURL.path + "/"
        let affected = mediaAssets.filter { $0.url.standardizedFileURL.path.hasPrefix(prefix) }.map(\.id)
        let newlyMissing = Set(affected).subtracting(missingMediaRefs)
        guard !newlyMissing.isEmpty else { return }
        missingMediaRefs.formUnion(newlyMissing)
        Log.project.info("volume unmounted offline=\(newlyMissing.count) path=\(volumeURL.lastPathComponent)")
        timelineRenderRevision &+= 1
        videoEngine?.rebuild()
    }

    func startWatchingVolumes() {
        guard volumeObservers.isEmpty else { return }
        let center = NSWorkspace.shared.notificationCenter
        volumeObservers = [
            center.addObserver(forName: NSWorkspace.didMountNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.relinkOfflineOriginals() }
            },
            center.addObserver(forName: NSWorkspace.didUnmountNotification, object: nil, queue: .main) { [weak self] note in
                let url = note.userInfo?[NSWorkspace.volumeURLUserInfoKey] as? URL
                MainActor.assumeIsolated {
                    guard let url else { return }
                    self?.markOriginalsOffline(onVolumeAt: url)
                }
            },
        ]
    }

    func stopWatchingVolumes() {
        let center = NSWorkspace.shared.notificationCenter
        for observer in volumeObservers { center.removeObserver(observer) }
        volumeObservers = []
        identityRelinkTask?.cancel()
        identityRelinkTask = nil
    }
}
