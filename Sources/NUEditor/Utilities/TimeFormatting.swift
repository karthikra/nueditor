import Foundation

func formatTimecode(frame: Int, fps: Int) -> String {
    guard fps > 0 else { return "00:00:00:00" }
    let absFrame = abs(frame)
    let totalSeconds = absFrame / fps
    let ff = absFrame % fps
    let ss = totalSeconds % 60
    let mm = (totalSeconds / 60) % 60
    let hh = totalSeconds / 3600
    let sign = frame < 0 ? "-" : ""
    return "\(sign)\(twoDigit(hh)):\(twoDigit(mm)):\(twoDigit(ss)):\(twoDigit(ff))"
}

private func twoDigit(_ value: Int) -> String {
    guard value >= 0 && value < 10 else { return "\(value)" }
    return "0\(value)"
}

func secondsToFrame(seconds: Double, fps: Int) -> Int {
    Int(seconds * Double(fps))
}

/// Seconds to frames at a project's exact rate. At 23.976 the nominal 24 overstates the count by
/// 0.1%, which is a frame of drift every ~42 seconds — the error this whole type exists to avoid.
func secondsToFrame(seconds: Double, rate: FrameRate) -> Int {
    rate.frame(seconds: seconds)
}

/// Non-drop timecode: frames are counted at the nominal rate, so 23.976 reads 00:00:01:00 after
/// 24 frames. Drop-frame (29.97 with dropped labels) is not implemented.
func formatTimecode(frame: Int, rate: FrameRate) -> String {
    formatTimecode(frame: frame, fps: rate.nominal)
}

extension Double {
    func rounded(toPlaces places: Int) -> Double {
        let factor = Foundation.pow(10.0, Double(places))
        return (self * factor).rounded() / factor
    }
}
