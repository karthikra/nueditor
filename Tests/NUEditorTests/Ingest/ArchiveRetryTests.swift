import Foundation
import Synchronization
import Testing
@testable import NUEditor

private final class PassCount: Sendable {
    private let count = Mutex(0)
    var value: Int { count.withLock { $0 } }
    func next() -> Int { count.withLock { value in defer { value += 1 }; return value } }
}

@Suite("IngestCoordinator — automatic archive retry")
@MainActor
struct ArchiveRetryTests {

    private func registeredAsset(in editor: EditorViewModel) -> MediaAsset {
        let asset = MediaAsset(url: URL(fileURLWithPath: "/Volumes/CARD/A001.mov"), type: .video, name: "A001")
        asset.footageIdentity = FootageIdentity(checksum: "a", fileSizeBytes: 10)
        asset.footageId = "f-a"
        editor.mediaAssets.append(asset)
        return asset
    }

    /// Answers each archive pass from `outcomes` in order, counting the passes.
    private func script(_ ingest: IngestCoordinator, _ outcomes: [OriginalArchiver.Outcome]) -> PassCount {
        let calls = PassCount()
        ingest.archiveRetryDelay = { _ in .zero }
        ingest.archiveFile = { _ in outcomes[min(calls.next(), outcomes.count - 1)] }
        return calls
    }

    @Test func anInterruptedArchiveRetriesUntilItLands() async throws {
        let editor = EditorViewModel()
        let asset = registeredAsset(in: editor)
        let calls = script(editor.ingest, [.interrupted("The network connection was lost."), .archived(uri: "s3://b/k")])

        editor.ingest.archiveOriginal(assetId: asset.id)
        await editor.ingest.archiveTask(assetId: asset.id)?.value
        #expect(editor.ingest.archiveOutcomes[asset.id] == .interrupted("The network connection was lost."))

        let retry = try #require(editor.ingest.pendingArchiveRetry(assetId: asset.id))
        await retry.value
        await editor.ingest.archiveTask(assetId: asset.id)?.value

        #expect(calls.value == 2)
        #expect(asset.originalArchiveURI == "s3://b/k")
        #expect(editor.ingest.pendingArchiveRetry(assetId: asset.id) == nil)
    }

    @Test(arguments: [
        OriginalArchiver.Outcome.skipped("The original is offline."),
        .failed("S3 refused to complete the upload"),
    ])
    func onlyAnInterruptionIsRetried(outcome: OriginalArchiver.Outcome) async {
        let editor = EditorViewModel()
        let asset = registeredAsset(in: editor)
        _ = script(editor.ingest, [outcome])

        editor.ingest.archiveOriginal(assetId: asset.id)
        await editor.ingest.archiveTask(assetId: asset.id)?.value
        #expect(editor.ingest.pendingArchiveRetry(assetId: asset.id) == nil)
    }

    @Test func closingTheProjectCancelsAPendingRetry() async throws {
        let editor = EditorViewModel()
        let asset = registeredAsset(in: editor)
        let calls = script(editor.ingest, [.interrupted("tower away")])
        editor.ingest.archiveRetryDelay = { _ in .seconds(3_600) }

        editor.ingest.archiveOriginal(assetId: asset.id)
        await editor.ingest.archiveTask(assetId: asset.id)?.value
        let retry = try #require(editor.ingest.pendingArchiveRetry(assetId: asset.id))

        editor.ingest.cancelAll()
        await retry.value
        #expect(calls.value == 1)
        #expect(editor.ingest.archiveTask(assetId: asset.id) == nil)
    }

    @Test func aReopenedLinkedProjectResumesUnfinishedArchives() async {
        let editor = EditorViewModel()
        editor.towerProjectId = "p-1"
        let asset = registeredAsset(in: editor)
        let calls = script(editor.ingest, [.archived(uri: "s3://b/k")])

        editor.ingest.resumeAfterRestore()
        await editor.ingest.archiveTask(assetId: asset.id)?.value
        #expect(calls.value == 1)
        #expect(asset.originalArchiveURI == "s3://b/k")
    }

    @Test(arguments: [(0, 30), (1, 30), (2, 60), (3, 120), (4, 240), (5, 480), (6, 600), (50, 600)])
    func retriesBackOffToATenMinuteCeiling(attempt: Int, seconds: Int64) {
        #expect(IngestCoordinator.archiveRetryDelay(afterAttempt: attempt) == .seconds(seconds))
    }
}
