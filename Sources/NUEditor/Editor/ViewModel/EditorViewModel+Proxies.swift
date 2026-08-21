import Foundation

extension EditorViewModel {
    /// URLs to *play* with: the preview proxy where one exists, the original otherwise.
    ///
    /// Export, conform, and XML never use this — they need the original's full quality. Keeping
    /// the substitution here rather than inside `MediaResolver` is what keeps that true.
    func playbackURLMap() -> [String: URL] {
        var map = mediaResolver.expectedURLMap()
        for (assetId, proxy) in previewProxyURLs where map[assetId] != nil || proxy.isFileURL {
            map[assetId] = proxy
        }
        return map
    }

    /// A proxy landed or went away — rebuild so playback picks it up.
    func refreshProxyPlayback() {
        videoEngine?.rebuild()
    }

    /// Project closing: stop protecting this project's proxies from eviction.
    func releaseProxyPins() {
        let checksums = Set(mediaAssets.compactMap { $0.footageIdentity?.checksum })
        previewProxyURLs = [:]
        guard !checksums.isEmpty else { return }
        Task { await ProxyCache.shared.unpin(checksums: checksums) }
    }

    /// Re-reads the proxy cache for every asset with a content identity, and pins those proxies so
    /// a large import can't evict what this project is playing. Off-main; commits on the main actor.
    func hydrateProxyPlayback() async {
        let identified = mediaAssets.compactMap { asset in
            asset.footageIdentity.map { (assetId: asset.id, checksum: $0.checksum) }
        }
        guard !identified.isEmpty else {
            if !previewProxyURLs.isEmpty {
                previewProxyURLs = [:]
                refreshProxyPlayback()
            }
            return
        }
        await ProxyCache.shared.pin(checksums: Set(identified.map(\.checksum)))
        var found: [String: URL] = [:]
        for item in identified {
            guard let url = await ProxyCache.shared.existing(checksum: item.checksum, kind: .preview) else { continue }
            found[item.assetId] = url
        }
        guard found != previewProxyURLs else { return }
        previewProxyURLs = found
        refreshProxyPlayback()
    }
}
