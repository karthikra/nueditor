import AVFoundation
import Foundation

/// The three derivatives edge ingest makes from a camera original. The original itself is never
/// one of them: it stays on its drive and never crosses the network.
enum ProxyKind: String, Sendable, CaseIterable {
    /// 720p H.264 — what the editor plays, so huge originals stay smooth and can go offline.
    case preview
    /// 480p / 5 fps H.264, no audio — what the tower's VLM reads.
    case vlm
    /// 16 kHz mono WAV — what the tower transcribes.
    case audio

    var fileExtension: String { self == .audio ? "wav" : "mp4" }

    /// Longest edge, so a vertical original proxies to 720 tall rather than 720 wide.
    var maxEdge: Int? {
        switch self {
        case .preview: 1280
        case .vlm: 854
        case .audio: nil
        }
    }

    var frameRate: Double? { self == .vlm ? 5 : nil }

    var includesAudio: Bool { self == .preview }

    var backendDerivative: NUEDITBackendClient.Derivative? {
        switch self {
        case .preview: .previewProxy
        case .vlm: .vlmProxy
        case .audio: .audio
        }
    }
}

/// Builds proxies with the hardware encoders. Every entry point is async and off the main actor;
/// output is staged under a caller-owned URL, so a cancelled build leaves a temp file, never a
/// half-written proxy in the cache.
enum ProxyBuilder {
    struct BuildError: LocalizedError {
        let reason: String
        var errorDescription: String? { reason }
    }

    /// Two encodes at a time: the media engine is the scarce resource, and a card import would
    /// otherwise queue one session per file.
    private static let gate = AsyncSemaphore(value: 2)

    static func build(_ kind: ProxyKind, from source: URL, to destination: URL) async throws {
        guard (try? await gate.wait()) != nil else { throw CancellationError() }
        defer { Task { await gate.signal() } }
        try Task.checkCancellation()

        switch kind {
        case .audio:
            let extracted = try await Transcription.extractAudioTrack(from: source, fileExtension: "wav")
            defer { try? FileManager.default.removeItem(at: extracted) }
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.moveItem(at: extracted, to: destination)
        case .preview, .vlm:
            try await buildVideo(kind, from: source, to: destination)
        }
    }

    private static func buildVideo(_ kind: ProxyKind, from source: URL, to destination: URL) async throws {
        let asset = AVURLAsset(url: source)
        guard let videoTrack = try await asset.loadTracks(withMediaType: .video).first else {
            throw BuildError(reason: "\(source.lastPathComponent) has no video track to proxy.")
        }
        let duration = try await asset.load(.duration)
        guard duration.isNumeric, duration > .zero else {
            throw BuildError(reason: "\(source.lastPathComponent) has no usable duration.")
        }
        let naturalSize = try await videoTrack.load(.naturalSize)
        let preferredTransform = try await videoTrack.load(.preferredTransform)
        let oriented = CGRect(origin: .zero, size: naturalSize).applying(preferredTransform)
        let displaySize = CGSize(width: abs(oriented.width), height: abs(oriented.height))
        guard displaySize.width > 0, displaySize.height > 0 else {
            throw BuildError(reason: "\(source.lastPathComponent) reports a zero-sized picture.")
        }
        let renderSize = proxySize(for: displaySize, maxEdge: kind.maxEdge ?? Int(displaySize.width))

        // Only the tracks this proxy needs: the VLM proxy carries no audio, so it stays small.
        let composition = AVMutableComposition()
        let range = CMTimeRange(start: .zero, duration: duration)
        guard let compVideo = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else {
            throw BuildError(reason: "Could not stage a video track for the proxy.")
        }
        try compVideo.insertTimeRange(range, of: videoTrack, at: .zero)
        if kind.includesAudio, let audioTrack = try await asset.loadTracks(withMediaType: .audio).first,
           let compAudio = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) {
            try? compAudio.insertTimeRange(range, of: audioTrack, at: .zero)
        }

        let videoComposition = AVMutableVideoComposition()
        videoComposition.renderSize = renderSize
        videoComposition.frameDuration = try await frameDuration(kind: kind, track: videoTrack)
        let instruction = AVMutableVideoCompositionInstruction()
        instruction.timeRange = CMTimeRange(start: .zero, duration: composition.duration)
        let layer = AVMutableVideoCompositionLayerInstruction(assetTrack: compVideo)
        layer.setTransform(fitTransform(displaySize: displaySize, preferredTransform: preferredTransform, into: renderSize), at: .zero)
        instruction.layerInstructions = [layer]
        videoComposition.instructions = [instruction]

        guard let session = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetMediumQuality) else {
            throw BuildError(reason: "This Mac can't encode a proxy for \(source.lastPathComponent).")
        }
        session.videoComposition = videoComposition
        try? FileManager.default.removeItem(at: destination)
        try Task.checkCancellation()
        try await session.export(to: destination, as: .mp4)
    }

    /// Fits the source into the proxy frame without cropping, preserving the source's own
    /// orientation. Dimensions stay even — H.264 requires it.
    static func proxySize(for displaySize: CGSize, maxEdge: Int) -> CGSize {
        let longest = max(displaySize.width, displaySize.height)
        let scale = min(1.0, Double(maxEdge) / longest)
        return CGSize(width: even(displaySize.width * scale), height: even(displaySize.height * scale))
    }

    static func fitTransform(
        displaySize: CGSize,
        preferredTransform: CGAffineTransform,
        into renderSize: CGSize
    ) -> CGAffineTransform {
        let scale = min(renderSize.width / displaySize.width, renderSize.height / displaySize.height)
        // preferredTransform can leave the picture off-origin; re-seat it before scaling.
        let box = CGRect(origin: .zero, size: displaySize)
        let seated = preferredTransform.concatenating(
            CGAffineTransform(translationX: -box.minX, y: -box.minY)
        )
        return seated.concatenating(CGAffineTransform(scaleX: scale, y: scale))
    }

    /// The VLM proxy is deliberately sparse; a proxy never runs faster than its source.
    private static func frameDuration(kind: ProxyKind, track: AVAssetTrack) async throws -> CMTime {
        let sourceRate = Double((try? await track.load(.nominalFrameRate)) ?? 0)
        let target = kind.frameRate.map { min($0, sourceRate > 0 ? sourceRate : $0) } ?? sourceRate
        guard target > 0 else { return CMTime(value: 1, timescale: 30) }
        return CMTime(seconds: 1 / target, preferredTimescale: 600)
    }

    private static func even(_ value: Double) -> Double {
        max(2, (value.rounded() / 2).rounded() * 2)
    }
}
