import Foundation
import Testing
@testable import NUEditor

@Suite("OriginalArchiver — camera originals to S3")
struct OriginalArchiverTests {

    private struct Fixture {
        let directory: URL
        let original: URL
        let identity: FootageIdentity
        let towerHost: String
        let s3Host: String
        let client: NUEDITBackendClient

        func request(identity: FootageIdentity? = nil, original: URL? = nil) -> OriginalArchiver.Request {
            OriginalArchiver.Request(
                footageId: "f-1", originalURL: original ?? self.original, identity: identity ?? self.identity
            )
        }

        var towerRequests: [StubHTTP.Recorded] { StubHTTP.requests(to: towerHost) }
        var s3Requests: [StubHTTP.Recorded] { StubHTTP.requests(to: s3Host) }

        func cleanUp() { try? FileManager.default.removeItem(at: directory) }
    }

    private static func json(_ object: [String: Any]) -> Data {
        (try? JSONSerialization.data(withJSONObject: object)) ?? Data()
    }

    /// A tower and an S3 endpoint with the given behaviour, and a real original on disk.
    private func fixture(
        presign: [String: Any]? = nil,
        grantHeaders: [String: String]? = nil,
        s3Status: Int = 200,
        s3Body: Data = Data(),
        complete: [String: Any] = ["footage_id": "f-1", "archived": true, "uri": "s3://nuedit-media/p/f-1/A001.mov", "bytes": 5]
    ) async throws -> Fixture {
        let directory = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let original = directory.appendingPathComponent("A001.mov")
        try Data("bytes".utf8).write(to: original)
        let (size, modified) = try FootageProbe.fileSizeAndModificationDate(of: original)
        let identity = FootageIdentity(
            checksum: "abc123", fileSizeBytes: size, volumeLabel: "CARD", contentModificationDate: modified
        )

        let s3Host = StubHTTP.host { _ in (s3Status, s3Body) }
        var grant = presign ?? [
            "footage_id": "f-1", "key": "p/f-1/A001.mov",
            "url": "https://\(s3Host)/p/f-1/A001.mov?X-Amz-Signature=sig", "expires_in": 3600,
        ]
        if let grantHeaders { grant["headers"] = grantHeaders }
        let grantBody = Self.json(grant), completeBody = Self.json(complete)
        let towerHost = StubHTTP.host { request in
            let path = request.url?.path ?? ""
            if path.hasSuffix("/archive/presign") { return (200, grantBody) }
            if path.hasSuffix("/archive/complete") { return (200, completeBody) }
            return (404, Self.json(["detail": "not stubbed"]))
        }
        let client = NUEDITBackendClient(session: StubHTTP.session())
        await client.use(NUEDITBackendSettings(baseURL: URL(string: "http://\(towerHost)"), token: "tower-token"))
        return Fixture(
            directory: directory, original: original, identity: identity,
            towerHost: towerHost, s3Host: s3Host, client: client
        )
    }

    @Test func archivesThroughPresignUploadAndComplete() async throws {
        let f = try await fixture()
        defer { f.cleanUp() }
        let outcome = await OriginalArchiver.archive(f.request(), client: f.client)
        #expect(outcome == .archived(uri: "s3://nuedit-media/p/f-1/A001.mov"))
        #expect(f.towerRequests.map(\.url.path) == ["/api/v1/footage/f-1/archive/presign", "/api/v1/footage/f-1/archive/complete"])
        #expect(f.s3Requests.map(\.method) == ["PUT"])
        let completeBody = try #require(f.towerRequests.last?.body)
        #expect(try JSONDecoder().decode([String: String].self, from: completeBody) == ["key": "p/f-1/A001.mov"])
    }

    // S3 rejects a request carrying two auth mechanisms, and the tower token must never reach S3.
    @Test func theUploadCarriesTheSignedHeadersAndNoBearerToken() async throws {
        let f = try await fixture()
        defer { f.cleanUp() }
        _ = await OriginalArchiver.archive(f.request(), client: f.client)
        let put = try #require(f.s3Requests.first)
        #expect(put.headers["Authorization"] == nil)
        #expect(put.headers["Content-Type"] == "application/octet-stream")
        #expect(f.towerRequests.first?.headers["Authorization"] == "Bearer tower-token")
    }

    @Test func headersTheTowerReturnsAreSentExactly() async throws {
        let f = try await fixture(grantHeaders: ["Content-Type": "video/quicktime", "x-amz-checksum-sha256": "q83v"])
        defer { f.cleanUp() }
        _ = await OriginalArchiver.archive(f.request(), client: f.client)
        let put = try #require(f.s3Requests.first)
        #expect(put.headers["Content-Type"] == "video/quicktime")
        #expect(put.headers["x-amz-checksum-sha256"] == "q83v")
    }

    // A presign leaves the tower's row `uploading`; only `complete` releases it for a retry.
    @Test func aRejectedUploadStillReleasesTheGrant() async throws {
        let f = try await fixture(
            s3Status: 403, s3Body: Data("<Error><Code>SignatureDoesNotMatch</Code></Error>".utf8),
            complete: ["footage_id": "f-1", "archived": false, "error": "object not found in S3 after upload"]
        )
        defer { f.cleanUp() }
        let outcome = await OriginalArchiver.archive(f.request(), client: f.client)
        #expect(f.towerRequests.last?.url.path == "/api/v1/footage/f-1/archive/complete")
        guard case .failed(let message) = outcome else {
            Issue.record("expected failed, got \(outcome)")
            return
        }
        #expect(message.contains("SignatureDoesNotMatch"))
    }

    // The bytes may have landed even when the response did not; the tower's check decides.
    @Test func aLostUploadResponseCountsWhenTheTowerFindsTheObject() async throws {
        let f = try await fixture(s3Status: 500)
        defer { f.cleanUp() }
        let outcome = await OriginalArchiver.archive(f.request(), client: f.client)
        #expect(outcome == .archived(uri: "s3://nuedit-media/p/f-1/A001.mov"))
    }

    @Test func aTowerRefusalIsReportedWithoutUploading() async throws {
        let f = try await fixture(presign: ["skipped": true, "reason": "project opted out", "archive_status": "pending"])
        defer { f.cleanUp() }
        let outcome = await OriginalArchiver.archive(f.request(), client: f.client)
        #expect(outcome == .skipped("The tower declined: project opted out."))
        #expect(f.s3Requests.isEmpty)
        #expect(f.towerRequests.count == 1)
    }

    @Test func alreadyArchivedIsSuccess() async throws {
        let f = try await fixture(presign: ["skipped": true, "reason": "already archived", "archive_status": "archived"])
        defer { f.cleanUp() }
        #expect(await OriginalArchiver.archive(f.request(), client: f.client) == .alreadyArchived)
        #expect(f.s3Requests.isEmpty)
    }

    // Presigning would strand the row in `uploading` for a file a single PUT can't carry.
    @Test func anOversizedOriginalNeverAsksForAGrant() async throws {
        let f = try await fixture()
        defer { f.cleanUp() }
        let outcome = await OriginalArchiver.archive(f.request(), client: f.client, singleUploadLimit: 1)
        guard case .skipped = outcome else {
            Issue.record("expected skipped, got \(outcome)")
            return
        }
        #expect(f.towerRequests.isEmpty)
    }

    // Uploading changed bytes under the old checksum would make the archive lie about its contents.
    @Test func aChangedOriginalIsNeverUploaded() async throws {
        let f = try await fixture()
        defer { f.cleanUp() }
        var stale = f.identity
        stale.fileSizeBytes += 1
        guard case .failed = await OriginalArchiver.archive(f.request(identity: stale), client: f.client) else {
            Issue.record("a changed original must fail")
            return
        }
        #expect(f.towerRequests.isEmpty)
        #expect(f.s3Requests.isEmpty)
    }

    @Test func anOfflineOriginalNamesTheDriveToMount() async throws {
        let f = try await fixture()
        defer { f.cleanUp() }
        let missing = f.directory.appendingPathComponent("gone.mov")
        let outcome = await OriginalArchiver.archive(f.request(original: missing), client: f.client)
        #expect(outcome == .skipped("The original is offline. Mount \"CARD\" to archive it."))
        #expect(f.towerRequests.isEmpty)
    }

    @Test func anUnreachableTowerSkips() async throws {
        let f = try await fixture()
        defer { f.cleanUp() }
        let client = NUEDITBackendClient()
        // Port 1 refuses immediately: a transport failure, not an API rejection.
        await client.use(NUEDITBackendSettings(baseURL: URL(string: "http://127.0.0.1:1"), token: nil))
        guard case .skipped = await OriginalArchiver.archive(f.request(), client: client) else {
            Issue.record("an unreachable tower must skip")
            return
        }
    }

    @Test func anUnconfiguredTowerSkips() async throws {
        let f = try await fixture()
        defer { f.cleanUp() }
        let client = NUEDITBackendClient()
        await client.use(NUEDITBackendSettings(baseURL: nil, token: nil))
        #expect(await OriginalArchiver.archive(f.request(), client: client) == .skipped("No tower configured."))
    }

    @Test(arguments: [
        (0, 3_600),
        (5 << 30, 5_120),
        (1 << 40, 86_400),
    ])
    func grantLifetimeCoversASlowUplinkWithinTheTowerBounds(bytes: Int, seconds: Int) {
        #expect(OriginalArchiver.grantLifetimeSeconds(forBytes: bytes) == seconds)
    }

    @Test func s3ErrorCodesAreReadFromTheXMLBody() {
        let body = Data("<?xml version=\"1.0\"?><Error><Code>RequestTimeTooSkewed</Code><Message>x</Message></Error>".utf8)
        #expect(NUEDITBackendClient.s3ErrorCode(from: body) == "RequestTimeTooSkewed")
        #expect(NUEDITBackendClient.s3ErrorCode(from: Data()) == nil)
    }
}

@Suite("FootageIdentity — has the original changed?")
struct FootageIdentityChangeTests {
    private let date = Date(timeIntervalSinceReferenceDate: 800_000_000)

    @Test func aDifferentSizeIsAChange() {
        let identity = FootageIdentity(checksum: "a", fileSizeBytes: 10, contentModificationDate: date)
        #expect(!identity.matches(fileSizeBytes: 11, contentModificationDate: date))
    }

    @Test func aDifferentModificationDateIsAChange() {
        let identity = FootageIdentity(checksum: "a", fileSizeBytes: 10, contentModificationDate: date)
        #expect(!identity.matches(fileSizeBytes: 10, contentModificationDate: date.addingTimeInterval(1)))
    }

    // Footage identified before the date was recorded is judged on size alone.
    @Test func anIdentityWithoutADateFallsBackToSize() {
        let identity = FootageIdentity(checksum: "a", fileSizeBytes: 10)
        #expect(identity.matches(fileSizeBytes: 10, contentModificationDate: date))
    }

    @Test func manifestsWrittenBeforeTheDateExistStillDecode() throws {
        let json = Data(#"{"checksum":"a","fileSizeBytes":10}"#.utf8)
        let identity = try JSONDecoder().decode(FootageIdentity.self, from: json)
        #expect(identity.contentModificationDate == nil)
    }

    @MainActor
    @Test func theArchiveLocationSurvivesTheManifest() {
        let asset = MediaAsset(url: URL(fileURLWithPath: "/Volumes/CARD/A001.mov"), type: .video, name: "A001")
        asset.originalArchiveURI = "s3://nuedit-media/p/f/A001.mov"
        let entry = asset.toManifestEntry(projectURL: nil)
        let restored = MediaAsset(entry: entry, resolvedURL: asset.url)
        #expect(restored.originalArchiveURI == "s3://nuedit-media/p/f/A001.mov")
    }
}
