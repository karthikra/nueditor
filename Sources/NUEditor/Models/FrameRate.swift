import CoreMedia

/// A project's frame rate, held exactly.
///
/// Broadcast rates are rationals: 23.976 *is* 24000/1001, and writing it as the decimal 23.976
/// produces a rate other tools read as something else (2997/125). So the rate is stored as the
/// nominal count — 24, 30, 60, which is what frames are counted in and what a user calls it —
/// plus the 1000/1001 pulldown that turns it into 23.976, 29.97, or 59.94.
///
/// Frame numbers are unchanged by the pulldown. Only the *time* a frame lands on moves, which is
/// why every conversion between frames and time goes through this type rather than `Double(fps)`.
struct FrameRate: Codable, Sendable, Equatable, Hashable {
    /// Frames per second as counted: 24 for both 24 and 23.976.
    var nominal: Int
    /// The 1000/1001 pulldown: 24 → 23.976, 30 → 29.97, 60 → 59.94.
    var isNTSC: Bool

    init(nominal: Int, isNTSC: Bool = false) {
        self.nominal = max(1, nominal)
        self.isNTSC = isNTSC
    }

    /// Rates that exist as an NTSC variant. 25 and 50 (PAL) have none.
    static let ntscCapableNominals = [24, 30, 60, 120]

    var supportsNTSC: Bool { Self.ntscCapableNominals.contains(nominal) }

    /// 24000 for 23.976, 24 for 24 — the denominator of the exact rational.
    var timescale: CMTimeScale { isNTSC ? CMTimeScale(nominal * 1000) : CMTimeScale(nominal) }

    /// 1001 for an NTSC rate, 1 otherwise: one frame is `frameDelta / timescale` seconds.
    var frameDelta: CMTimeValue { isNTSC ? 1001 : 1 }

    var frameDuration: CMTime { CMTime(value: frameDelta, timescale: timescale) }

    /// The real rate, for display and for anything that must speak in decimals.
    var framesPerSecond: Double {
        isNTSC ? Double(nominal) * 1000 / 1001 : Double(nominal)
    }

    var secondsPerFrame: Double { 1 / framesPerSecond }

    /// Exact time of a frame boundary — never `Double` arithmetic.
    func time(frame: Int) -> CMTime {
        CMTime(value: CMTimeValue(frame) * frameDelta, timescale: timescale)
    }

    /// Exact duration of a frame count.
    func duration(frames: Int) -> CMTime { time(frame: frames) }

    /// Truncating, matching how a clip's length is derived from its media: a source running a
    /// hair past a frame boundary does not gain a frame.
    func frame(seconds: Double) -> Int {
        guard seconds.isFinite else { return 0 }
        return Int(seconds * framesPerSecond)
    }

    func seconds(frame: Int) -> Double { Double(frame) * secondsPerFrame }

    /// "23.976", "24" — what the rate is called, not a rounded approximation of it.
    var displayName: String {
        guard isNTSC else { return "\(nominal)" }
        switch nominal {
        case 24: return "23.976"
        case 30: return "29.97"
        case 60: return "59.94"
        case 120: return "119.88"
        default: return String(format: "%.3f", framesPerSecond)
        }
    }

    /// The rational other tools need: 24000/1001, never the decimal.
    var rational: (numerator: Int, denominator: Int) {
        isNTSC ? (nominal * 1000, 1001) : (nominal, 1)
    }

    /// Matches a measured rate (an asset's reported fps) to a project rate. 23.976 and 23.98 are
    /// the same rate written differently, so the match is by proximity, not equality.
    static func matching(framesPerSecond rate: Double) -> FrameRate? {
        guard rate.isFinite, rate > 0 else { return nil }
        let candidates = (1...240).flatMap { nominal in
            [FrameRate(nominal: nominal), FrameRate(nominal: nominal, isNTSC: true)]
        }
        return candidates.min { abs($0.framesPerSecond - rate) < abs($1.framesPerSecond - rate) }
            .flatMap { abs($0.framesPerSecond - rate) < 0.02 ? $0 : nil }
    }
}
