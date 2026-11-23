import AVFoundation
import CoreGraphics

/// Card frames for the storyboard, pulled from footage this Mac already holds (its preview proxy,
/// else the original) at the moment NUEDIT names. Image bytes never cross the network.
///
/// Off the main actor, two decodes at a time, identical requests share one decode, and a bounded
/// cache keeps scrolling back cheap.
actor StoryboardFrameCache {
    static let shared = StoryboardFrameCache()

    static let capacity = 400
    static let maxPixelSize = CGSize(width: 480, height: 480)

    private struct Key: Hashable {
        let path: String
        let milliseconds: Int
    }

    private var images: [Key: CGImage] = [:]
    private var order: [Key] = []
    private var inFlight: [Key: Task<CGImage?, Never>] = [:]
    private let gate = AsyncSemaphore(value: 2)

    func frame(of url: URL, atMilliseconds milliseconds: Int) async -> CGImage? {
        let key = Key(path: url.standardizedFileURL.path, milliseconds: max(0, milliseconds))
        if let cached = images[key] {
            touch(key)
            return cached
        }
        if let running = inFlight[key] { return await running.value }

        let task = Task { [gate] () -> CGImage? in
            guard (try? await gate.wait()) != nil else { return nil }
            defer { Task { await gate.signal() } }
            guard !Task.isCancelled else { return nil }
            return await Self.decode(url, at: key.milliseconds)
        }
        inFlight[key] = task
        let image = await task.value
        inFlight[key] = nil
        if let image { store(image, for: key) }
        return image
    }

    @concurrent
    private static func decode(_ url: URL, at milliseconds: Int) async -> CGImage? {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = maxPixelSize
        generator.requestedTimeToleranceBefore = CMTime(value: 1, timescale: 4)
        generator.requestedTimeToleranceAfter = CMTime(value: 1, timescale: 4)
        let time = CMTime(value: CMTimeValue(milliseconds), timescale: 1000)
        return try? await generator.image(at: time).image
    }

    private func store(_ image: CGImage, for key: Key) {
        images[key] = image
        touch(key)
        while order.count > Self.capacity {
            images[order.removeFirst()] = nil
        }
    }

    private func touch(_ key: Key) {
        order.removeAll { $0 == key }
        order.append(key)
    }
}
