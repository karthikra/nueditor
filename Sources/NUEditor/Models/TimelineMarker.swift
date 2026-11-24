import Foundation

/// A note pinned to a point or range of a timeline, in project frames.
///
/// Markers flag what the cut still needs, e.g. NUEDIT's rough cut marks beats it had no footage
/// for. They stay at their frames when clips around them move.
struct TimelineMarker: Codable, Sendable, Equatable, Identifiable {
    /// Raw values are the MCP contract and the saved format.
    enum Kind: String, Codable, Sendable, CaseIterable {
        case note
        /// A beat with no usable footage.
        case missing
        /// Footage placed on a weak match; check it.
        case lowConfidence = "low_confidence"
        /// The script has no visual for this beat.
        case scriptGap = "script_gap"
        /// Another take that could go here.
        case alternate

        init(from decoder: Decoder) throws {
            // A kind from a newer build reads as a note rather than losing every marker.
            self = Kind(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .note
        }
    }

    var id: String = UUID().uuidString
    var frame: Int
    /// Zero marks a point; more marks a range starting at `frame`.
    var durationFrames: Int = 0
    var kind: Kind = .note
    var text: String = ""

    var endFrame: Int { frame + durationFrames }
}
