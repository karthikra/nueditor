import AVFoundation
import CoreGraphics

/// Decides whether a splice is a jump cut — the same framing cut against itself, which pops —
/// or a genuine picture change, which reads as an intentional cut and must stay hard.
///
/// Uses the same 8×8 luma fingerprint the search indexer uses for shot changes, so "different
/// shot" means one thing in this app.
enum JumpCutDetector {
    /// Below the indexer's shot-change threshold the two sides are the same framing.
    static let sameFramingDiff: Float = 12
    /// Two frames this close are indistinguishable — a freeze, black, or a still. Nothing pops,
    /// so there is nothing to soften.
    static let identicalDiff: Float = 0.5

    /// Sampled sides of one splice, in source seconds.
    struct Boundary: Sendable {
        let outgoingURL: URL
        let outgoingSeconds: Double
        let incomingURL: URL
        let incomingSeconds: Double
    }

    static func isJumpCut(before: CGImage, after: CGImage) -> Bool? {
        guard let a = LumaGrid.compute(before), let b = LumaGrid.compute(after) else { return nil }
        let diff = LumaGrid.meanDiff(a, b)
        return diff > identicalDiff && diff < sameFramingDiff
    }

    /// Samples both sides of a splice and reports whether it pops. Nil when either side
    /// can't be read — an unmeasured boundary must not be presented as a clean one.
    @concurrent
    static func isJumpCut(at boundary: Boundary) async -> Bool? {
        async let before = frame(url: boundary.outgoingURL, seconds: boundary.outgoingSeconds)
        async let after = frame(url: boundary.incomingURL, seconds: boundary.incomingSeconds)
        guard let before = await before, let after = await after else { return nil }
        return isJumpCut(before: before, after: after)
    }

    private static func frame(url: URL, seconds: Double) async -> CGImage? {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 256, height: 256)
        // The frames either side of a splice are the measurement; a nearby sync frame is not.
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        let time = CMTime(seconds: max(0, seconds), preferredTimescale: 600)
        return try? await generator.image(at: time).image
    }
}
