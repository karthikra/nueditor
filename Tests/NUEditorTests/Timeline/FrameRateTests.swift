import AVFoundation
import Testing
@testable import NUEditor

@Suite("FrameRate — broadcast rates are rationals")
struct FrameRateTests {

    @Test func ntscRatesAreExactRationalsNotDecimals() {
        let rate = FrameRate(nominal: 24, isNTSC: true)
        // 24000/1001, never 23.976 — a decimal is a different rate to every other tool.
        #expect(rate.rational == (24000, 1001))
        #expect(rate.timescale == 24000)
        #expect(rate.frameDelta == 1001)
        #expect(rate.displayName == "23.976")
        #expect(abs(rate.framesPerSecond - 23.976023976) < 1e-6)
    }

    @Test func wholeRatesStayWhole() {
        let rate = FrameRate(nominal: 24)
        #expect(rate.rational == (24, 1))
        #expect(rate.frameDelta == 1)
        #expect(rate.displayName == "24")
        #expect(rate.framesPerSecond == 24)
    }

    // The pulldown moves when a frame lands, not which frame it is.
    @Test func frameNumbersAreUnchangedByThePulldown() {
        let whole = FrameRate(nominal: 24)
        let ntsc = FrameRate(nominal: 24, isNTSC: true)
        #expect(whole.time(frame: 100) == CMTime(value: 100, timescale: 24))
        #expect(ntsc.time(frame: 100) == CMTime(value: 100_100, timescale: 24000))
        // Same frame number, 0.1% later in time.
        #expect(ntsc.time(frame: 100).seconds > whole.time(frame: 100).seconds)
        #expect(abs(ntsc.time(frame: 100).seconds / whole.time(frame: 100).seconds - 1.001) < 1e-9)
    }

    // A frame every ~42s is the drift this type exists to prevent.
    @Test func anHourOfFramesLandsExactlyWhereBroadcastSays() {
        let rate = FrameRate(nominal: 24, isNTSC: true)
        let hour = rate.time(frame: 24 * 60 * 60)
        #expect(hour.timescale == 24000)
        #expect(hour.value == 86_400 * 1001)
        #expect(abs(hour.seconds - 3603.6) < 1e-6)   // 3600 s of NTSC frames is 3603.6 real seconds
    }

    @Test func secondsRoundTripThroughFrames() {
        let rate = FrameRate(nominal: 30, isNTSC: true)
        for frame in [0, 1, 29, 30, 1000, 100_000] {
            #expect(rate.frame(seconds: rate.seconds(frame: frame)) == frame, "frame \(frame)")
        }
    }

    @Test func secondsToFramesTruncatesRatherThanRounding() {
        let rate = FrameRate(nominal: 24, isNTSC: true)
        // 5 s of 23.976 is 119.88 frames: a clip does not gain a frame it hasn't got.
        #expect(rate.frame(seconds: 5.0) == 119)
        // And exactly 120 frames' worth of time is 120 frames, not 119.
        #expect(rate.frame(seconds: 5.005) == 120)
        #expect(rate.frame(seconds: -0.0) == 0)
        #expect(rate.frame(seconds: .nan) == 0)
        #expect(rate.frame(seconds: .infinity) == 0)
    }

    @Test func onlyBroadcastFamiliesHaveAnNTSCVariant() {
        #expect(FrameRate(nominal: 24).supportsNTSC)
        #expect(FrameRate(nominal: 30).supportsNTSC)
        #expect(FrameRate(nominal: 60).supportsNTSC)
        #expect(!FrameRate(nominal: 25).supportsNTSC)   // PAL has no pulldown
        #expect(!FrameRate(nominal: 50).supportsNTSC)
    }

    @Test func frameDurationIsTheRatesReciprocal() {
        #expect(FrameRate(nominal: 30).frameDuration == CMTime(value: 1, timescale: 30))
        #expect(FrameRate(nominal: 30, isNTSC: true).frameDuration == CMTime(value: 1001, timescale: 30000))
    }

    // A measured rate off an asset is never exactly 23.976; matching is by proximity.
    @Test func measuredRatesMatchTheirBroadcastRate() {
        #expect(FrameRate.matching(framesPerSecond: 23.976) == FrameRate(nominal: 24, isNTSC: true))
        #expect(FrameRate.matching(framesPerSecond: 23.98) == FrameRate(nominal: 24, isNTSC: true))
        #expect(FrameRate.matching(framesPerSecond: 24.0) == FrameRate(nominal: 24))
        #expect(FrameRate.matching(framesPerSecond: 29.97) == FrameRate(nominal: 30, isNTSC: true))
        #expect(FrameRate.matching(framesPerSecond: 0) == nil)
        #expect(FrameRate.matching(framesPerSecond: .nan) == nil)
    }

    @Test func timelineCarriesTheRateThroughACodableRoundTrip() throws {
        var timeline = Fixtures.timeline(fps: 24)
        timeline.ntsc = true
        let decoded = try JSONDecoder().decode(Timeline.self, from: try JSONEncoder().encode(timeline))
        #expect(decoded.frameRate == FrameRate(nominal: 24, isNTSC: true))
    }

    // Projects written before fractional rates existed open as whole-rate projects.
    @Test func projectsWithoutTheFlagAreWholeRate() throws {
        let json = #"{"id":"t","name":"T","fps":24,"width":1920,"height":1080,"tracks":[]}"#
        let decoded = try JSONDecoder().decode(Timeline.self, from: Data(json.utf8))
        #expect(!decoded.ntsc)
        #expect(decoded.frameRate == FrameRate(nominal: 24))
    }

    // Non-drop timecode counts at the nominal rate: 24 frames of 23.976 reads one second.
    @Test func timecodeCountsAtTheNominalRate() {
        #expect(formatTimecode(frame: 24, rate: FrameRate(nominal: 24, isNTSC: true)) == "00:00:01:00")
        #expect(formatTimecode(frame: 24, rate: FrameRate(nominal: 24)) == "00:00:01:00")
    }
}

@Suite("Project settings — fractional rates")
@MainActor
struct FractionalRateSettingsTests {

    // Switching 24 → 23.976 must not move a single clip: the frames are the same frames.
    @Test func adoptingThePulldownRescalesNothing() {
        let vm = EditorViewModel()
        vm.timeline = Fixtures.timeline(fps: 24, tracks: [
            Fixtures.videoTrack(clips: [Fixtures.clip(id: "a", start: 48, duration: 96)]),
        ])
        vm.applyTimelineSettings(fps: 24, ntsc: true, width: 1920, height: 1080)

        let clip = vm.timeline.tracks[0].clips[0]
        #expect(clip.startFrame == 48)
        #expect(clip.durationFrames == 96)
        #expect(vm.timeline.frameRate == FrameRate(nominal: 24, isNTSC: true))
    }

    @Test func changingTheNominalRateStillRescales() {
        let vm = EditorViewModel()
        vm.timeline = Fixtures.timeline(fps: 24, tracks: [
            Fixtures.videoTrack(clips: [Fixtures.clip(id: "a", start: 24, duration: 48)]),
        ])
        vm.applyTimelineSettings(fps: 48, width: 1920, height: 1080)
        let clip = vm.timeline.tracks[0].clips[0]
        #expect(clip.startFrame == 48)
        #expect(clip.durationFrames == 96)
    }

    // A rate with no NTSC variant must not silently become one.
    @Test func palRatesRefuseThePulldown() {
        let vm = EditorViewModel()
        vm.timeline = Fixtures.timeline(fps: 25)
        vm.applyTimelineSettings(fps: 25, ntsc: true, width: 1920, height: 1080)
        #expect(!vm.timeline.ntsc)
    }

    @Test func settingsAreProjectWideAcrossTimelines() {
        let vm = EditorViewModel()
        vm.timelines = [Fixtures.timeline(fps: 24), Fixtures.timeline(fps: 24)]
        vm.activeTimelineId = vm.timelines[0].id
        vm.applyTimelineSettings(fps: 24, ntsc: true, width: 1920, height: 1080)
        #expect(vm.timelines.allSatisfy { $0.ntsc })
    }
}

@Suite("CompositionBuilder — a 23.976 project")
struct FractionalRateCompositionTests {

    @Test func compositionRunsOnTheExactBroadcastGrid() async throws {
        let source = try await FixtureVideo.write(
            scenes: [FixtureVideo.Scene(rgb: (0, 0, 255), seconds: 2)], fps: 24, size: 64
        )
        defer { try? FileManager.default.removeItem(at: source) }
        var timeline = Fixtures.timeline(fps: 24, tracks: [
            Fixtures.videoTrack(clips: [Fixtures.clip(id: "a", mediaRef: "v", start: 0, duration: 24)]),
        ])
        timeline.ntsc = true

        let result = try await CompositionBuilder.build(
            timeline: timeline,
            resolveURL: { $0 == "v" ? source : nil },
            renderSize: CGSize(width: 320, height: 180)
        )

        // The render grid is 1001/24000, not 1/24 and not a decimal approximation of it.
        #expect(result.videoComposition.frameDuration == CMTime(value: 1001, timescale: 24000))
        // 24 frames of 23.976 run 1.001 s, which is what makes conformed 24000/1001 media match.
        #expect(abs(result.composition.duration.seconds - 1.001) < 1e-6)
    }

    @Test func aWholeRateProjectIsUnaffected() async throws {
        let source = try await FixtureVideo.write(
            scenes: [FixtureVideo.Scene(rgb: (0, 255, 0), seconds: 2)], fps: 24, size: 64
        )
        defer { try? FileManager.default.removeItem(at: source) }
        let timeline = Fixtures.timeline(fps: 24, tracks: [
            Fixtures.videoTrack(clips: [Fixtures.clip(id: "a", mediaRef: "v", start: 0, duration: 24)]),
        ])
        let result = try await CompositionBuilder.build(
            timeline: timeline,
            resolveURL: { $0 == "v" ? source : nil },
            renderSize: CGSize(width: 320, height: 180)
        )
        #expect(result.videoComposition.frameDuration == CMTime(value: 1, timescale: 24))
        #expect(abs(result.composition.duration.seconds - 1.0) < 1e-6)
    }
}

@Suite("set_project_settings — fractional rates over MCP")
@MainActor
struct FractionalRateToolTests {

    @Test func theTowerCanCreateATrue23976Project() async throws {
        let h = ToolHarness(timeline: Fixtures.timeline(fps: 30))
        let payload = try await h.runOK("set_project_settings", args: ["fps": 24, "ntsc": true]) as? [String: Any]
        #expect(payload?["fps"] as? Int == 24)
        #expect(payload?["ntsc"] as? Bool == true)
        #expect(payload?["fpsRational"] as? String == "24000/1001")
        #expect(h.editor.timeline.frameRate == FrameRate(nominal: 24, isNTSC: true))
    }

    @Test func getTimelineReportsTheExactRate() async throws {
        let h = ToolHarness(timeline: Fixtures.timeline(fps: 30))
        _ = try await h.runOK("set_project_settings", args: ["fps": 24, "ntsc": true])
        let payload = try await h.runOK("get_timeline") as? [String: Any]
        #expect(payload?["fps"] as? Int == 24)
        #expect(payload?["ntsc"] as? Bool == true)
        #expect(payload?["fpsRational"] as? String == "24000/1001")
        let exact = payload?["fpsExact"] as? Double ?? 0
        #expect(abs(exact - 23.976) < 0.001)
    }

    // A rate with no NTSC variant is refused rather than silently ignored.
    @Test func palRatesRejectThePulldown() async {
        let h = ToolHarness(timeline: Fixtures.timeline(fps: 30))
        let result = await h.runRaw("set_project_settings", args: ["fps": 25, "ntsc": true])
        #expect(result.isError)
        #expect(ToolHarness.textOf(result).contains("23.976"))
    }

    @Test func droppingThePulldownReturnsToTheWholeRate() async throws {
        let h = ToolHarness(timeline: Fixtures.timeline(fps: 30))
        _ = try await h.runOK("set_project_settings", args: ["fps": 24, "ntsc": true])
        let payload = try await h.runOK("set_project_settings", args: ["ntsc": false]) as? [String: Any]
        #expect(payload?["ntsc"] as? Bool == false)
        #expect(h.editor.timeline.frameRate == FrameRate(nominal: 24))
    }
}

@Suite("Export — a 23.976 project reaches the file")
struct FractionalRateExportTests {

    // The promise the tower is building against: material conformed to 24000/1001 matches this
    // project exactly. That only holds if the exported file really carries the rate.
    @Test func exportedMediaCarriesTheBroadcastRate() async throws {
        let source = try await FixtureVideo.write(
            scenes: [FixtureVideo.Scene(rgb: (255, 128, 0), seconds: 2)], fps: 24, size: 128
        )
        let output = URL.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).mp4")
        defer {
            try? FileManager.default.removeItem(at: source)
            try? FileManager.default.removeItem(at: output)
        }
        var timeline = Fixtures.timeline(fps: 24, tracks: [
            Fixtures.videoTrack(clips: [Fixtures.clip(id: "a", mediaRef: "v", start: 0, duration: 48)]),
        ])
        timeline.ntsc = true

        let result = try await CompositionBuilder.build(
            timeline: timeline,
            resolveURL: { $0 == "v" ? source : nil },
            renderSize: CGSize(width: 320, height: 180)
        )
        let session = try #require(AVAssetExportSession(asset: result.composition, presetName: AVAssetExportPresetMediumQuality))
        session.videoComposition = result.videoComposition
        try await session.export(to: output, as: .mp4)

        let exported = AVURLAsset(url: output)
        let track = try #require(try await exported.loadTracks(withMediaType: .video).first)
        let rate = Double(try await track.load(.nominalFrameRate))
        #expect(abs(rate - 23.976) < 0.02, "exported at \(rate), not 23.976")
        // 48 frames of 23.976 is 2.002 s — the 0.1% is the whole point.
        #expect(abs(try await exported.load(.duration).seconds - 2.002) < 0.02)
    }
}
