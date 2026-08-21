import Foundation

/// Runs edge ingest behind an import: content identity first, then (later stages) proxies and
/// registration with the tower.
///
/// Nothing here blocks the drop — the clip is editable the instant it lands, and every step is
/// cancellable, resumable, and safe to run with no tower at all.
@MainActor
final class IngestCoordinator {
    private weak var editor: EditorViewModel?
    private var work: [String: Task<Void, Never>] = [:]
    /// Hashing is disk-bound and a card import can be hundreds of files; two at a time keeps the
    /// drive busy without starving playback reads.
    private let gate = AsyncSemaphore(value: 2)

    init(editor: EditorViewModel) {
        self.editor = editor
    }

    /// Footage that originates on this machine: real camera media referenced in place. Generated
    /// results and stills arrive by other paths and are not edge ingest.
    static func isEligible(_ asset: MediaAsset) -> Bool {
        (asset.type == .video || asset.type == .audio)
            && asset.generationInput == nil
            && asset.pendingDownloadURL == nil
    }

    /// Idempotent: an asset already identified, in flight, or ineligible is left alone.
    func ingest(_ asset: MediaAsset) {
        guard Self.isEligible(asset), asset.footageIdentity == nil, work[asset.id] == nil else { return }
        let assetId = asset.id
        asset.ingestStatus = .queued
        work[assetId] = Task { @MainActor [weak self] in
            defer { self?.work[assetId] = nil }
            await self?.identify(assetId: assetId)
        }
    }

    func cancel(assetId: String) {
        work.removeValue(forKey: assetId)?.cancel()
    }

    /// Quit, close, or project switch: stop hashing, leave no half state behind.
    func cancelAll() {
        for task in work.values { task.cancel() }
        work.removeAll()
    }

    private func identify(assetId: String) async {
        guard let editor, let asset = editor.mediaAssets.first(where: { $0.id == assetId }) else { return }
        let url = asset.url

        // Install the release only once the permit is actually held.
        guard (try? await gate.wait()) != nil else { return }
        defer { Task { await gate.signal() } }
        guard !Task.isCancelled, current(assetId: assetId)?.url == url else { return }

        asset.ingestStatus = .identifying
        do {
            let identity = try await FootageProbe.identity(of: url)
            try Task.checkCancellation()
            // The library can move on while a large file hashes: only commit to the same asset,
            // still pointing at the same file.
            guard let live = current(assetId: assetId), live.url == url else { return }
            live.footageIdentity = identity
            live.ingestStatus = .local
            editor.queueManifestMetadataUpdate(for: live)
            Log.project.info(
                "ingest identified asset=\(assetId.prefix(8)) bytes=\(identity.fileSizeBytes) codec=\(identity.codec ?? "?")"
            )
            await buildProxies(assetId: assetId, identity: identity, sourceURL: url)
        } catch is CancellationError {
            if let live = current(assetId: assetId), live.ingestStatus.isActive { live.ingestStatus = .queued }
        } catch {
            guard let live = current(assetId: assetId), live.url == url else { return }
            live.ingestStatus = .failed(Log.detail(error))
            editor.queueManifestMetadataUpdate(for: live)
            Log.project.warning("ingest identify failed asset=\(assetId.prefix(8)): \(Log.detail(error))")
        }
    }

    /// Builds whatever proxies this footage is missing. Partial success is real success: a video
    /// whose audio can't be extracted still gets its picture proxies, and each is installed
    /// atomically so a cancelled build never leaves a usable-looking file.
    private func buildProxies(assetId: String, identity: FootageIdentity, sourceURL: URL) async {
        guard let editor, let asset = current(assetId: assetId) else { return }
        let kinds = Self.proxyKinds(for: asset)
        guard !kinds.isEmpty else { return }
        asset.ingestStatus = .proxying

        var built = 0
        for kind in kinds {
            guard !Task.isCancelled else { break }
            if await ProxyCache.shared.existing(checksum: identity.checksum, kind: kind) != nil {
                built += 1
                continue
            }
            do {
                let staged = try await ProxyCache.shared.stagingURL(checksum: identity.checksum, kind: kind)
                do {
                    try await ProxyBuilder.build(kind, from: sourceURL, to: staged)
                    try await ProxyCache.shared.install(staged, checksum: identity.checksum, kind: kind)
                    built += 1
                } catch {
                    try? FileManager.default.removeItem(at: staged)
                    throw error
                }
            } catch is CancellationError {
                break
            } catch {
                // A missing audio track or an unsupported codec is not an ingest failure; the
                // other derivatives still carry the footage to the tower.
                Log.project.warning("proxy \(kind.rawValue) failed asset=\(assetId.prefix(8)): \(Log.detail(error))")
            }
        }
        await ProxyCache.shared.evictToBudget()

        guard let live = current(assetId: assetId), live.url == sourceURL else { return }
        live.ingestStatus = .local
        editor.queueManifestMetadataUpdate(for: live)
        Log.project.info("ingest proxies asset=\(assetId.prefix(8)) built=\(built)/\(kinds.count)")
        await editor.hydrateProxyPlayback()
        await register(assetId: assetId, identity: identity, kinds: kinds)
    }

    /// Hands the derivatives to the tower. Never the original. An unreachable tower, an
    /// unconfigured one, or a project with no tower link all leave the footage local and
    /// re-registerable later — none of them is an ingest failure.
    private func register(assetId: String, identity: FootageIdentity, kinds: [ProxyKind]) async {
        guard let editor, let asset = current(assetId: assetId) else { return }
        guard asset.footageId == nil else { return }
        guard let projectId = editor.towerProjectId else { return }

        var derivatives: [ProxyKind: URL] = [:]
        for kind in kinds {
            guard let url = await ProxyCache.shared.existing(checksum: identity.checksum, kind: kind) else { continue }
            derivatives[kind] = url
        }
        guard !derivatives.isEmpty else { return }

        guard let live = current(assetId: assetId) else { return }
        live.ingestStatus = .uploading
        let request = EdgeRegistrar.Request(
            projectId: projectId,
            filename: live.url.lastPathComponent,
            durationMilliseconds: Int((live.duration * 1000).rounded()),
            identity: identity,
            frameRate: live.sourceFPS,
            width: live.sourceWidth,
            height: live.sourceHeight,
            hasAudio: live.hasAudio,
            derivatives: derivatives
        )
        let outcome = await EdgeRegistrar.register(request)
        guard let settled = current(assetId: assetId) else { return }
        switch outcome {
        case .registered(let footageId, let duplicate):
            settled.footageId = footageId
            settled.ingestStatus = .registered(footageId)
            Log.project.info("ingest registered asset=\(assetId.prefix(8)) footage=\(footageId) duplicate=\(duplicate)")
        case .skipped(let reason):
            settled.ingestStatus = .local
            Log.project.info("ingest not registered asset=\(assetId.prefix(8)): \(reason)")
        case .failed(let message):
            settled.ingestStatus = .failed(message)
            Log.project.warning("ingest register failed asset=\(assetId.prefix(8)): \(message)")
        }
        editor.queueManifestMetadataUpdate(for: settled)
    }

    /// Registers anything already identified and proxied that the tower has not seen — the retry
    /// for footage imported while the tower was away, and for a project linked after the fact.
    func registerPendingFootage() {
        guard let editor, editor.towerProjectId != nil else { return }
        for asset in editor.mediaAssets
        where Self.isEligible(asset) && asset.footageId == nil && work[asset.id] == nil {
            guard let identity = asset.footageIdentity else {
                ingest(asset)
                continue
            }
            let assetId = asset.id
            let kinds = Self.proxyKinds(for: asset)
            work[assetId] = Task { @MainActor [weak self] in
                defer { self?.work[assetId] = nil }
                await self?.register(assetId: assetId, identity: identity, kinds: kinds)
            }
        }
    }

    /// Audio-only footage has no picture to proxy; video gets all three.
    static func proxyKinds(for asset: MediaAsset) -> [ProxyKind] {
        switch asset.type {
        case .video: asset.hasAudio ? [.preview, .vlm, .audio] : [.preview, .vlm]
        case .audio: [.audio]
        default: []
        }
    }

    private func current(assetId: String) -> MediaAsset? {
        editor?.mediaAssets.first { $0.id == assetId }
    }
}
