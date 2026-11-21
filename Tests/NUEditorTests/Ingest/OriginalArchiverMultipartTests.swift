import CryptoKit
import Foundation
import Testing
@testable import NUEditor

@Suite("OriginalArchiver — multipart originals")
struct OriginalArchiverMultipartTests {

    private static let contents = Data("0123456789".utf8)
    private static let partSize = 4
    private static let uploadId = "up-1"
    private static let uri = "s3://nuedit-media/p/f-1/A001.mov"

    private struct Fixture {
        let directory: URL
        let original: URL
        let identity: FootageIdentity
        let towerHost: String
        let s3Host: String
        let client: NUEDITBackendClient
        let journal: ArchiveUploadJournal

        func archive() async -> OriginalArchiver.Outcome {
            await OriginalArchiver.archive(
                OriginalArchiver.Request(footageId: "f-1", originalURL: original, identity: identity),
                client: client, journal: journal, singleUploadLimit: 5
            )
        }

        var towerPaths: [String] { StubHTTP.requests(to: towerHost).map(\.url.path) }
        var partPuts: [StubHTTP.Recorded] { StubHTTP.requests(to: s3Host).filter { $0.method == "PUT" } }
        func towerBody(endingWith suffix: String) throws -> [String: Any] {
            let body = try #require(StubHTTP.requests(to: towerHost).last { $0.url.path.hasSuffix(suffix) }?.body)
            return try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        }

        func cleanUp() { try? FileManager.default.removeItem(at: directory) }
    }

    private static func json(_ object: Any) -> Data {
        (try? JSONSerialization.data(withJSONObject: object)) ?? Data()
    }

    private static func partNumber(of request: URLRequest) -> Int? {
        URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?
            .queryItems?.first { $0.name == "partNumber" }?.value.flatMap(Int.init)
    }

    static func checksum(_ data: Data) -> String { Data(SHA256.hash(data: data)).base64EncodedString() }

    private func fixture(
        start: [String: Any]? = nil,
        failingPart: (number: Int, status: Int, code: String)? = nil,
        complete: [String: Any] = ["footage_id": "f-1", "archived": true, "uri": uri]
    ) async throws -> Fixture {
        let directory = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let original = directory.appendingPathComponent("A001.mov")
        try Self.contents.write(to: original)
        let (size, modified) = try FootageProbe.fileSizeAndModificationDate(of: original)
        let identity = FootageIdentity(checksum: "whole-file-sha", fileSizeBytes: size, contentModificationDate: modified)

        let s3Host = StubHTTP.host(withHeaders: { request in
            let number = Self.partNumber(of: request) ?? 0
            if let failingPart, failingPart.number == number {
                return (failingPart.status, [:], Data("<Error><Code>\(failingPart.code)</Code></Error>".utf8))
            }
            return (200, ["ETag": "\"etag-\(number)\""], Data())
        })
        let startBody = Self.json(start ?? [
            "footage_id": "f-1", "key": "p/f-1/A001.mov", "upload_id": Self.uploadId,
            "part_size": Self.partSize, "part_count": 3, "checksum_algorithm": "SHA256",
        ])
        let completeBody = Self.json(complete)
        let towerHost = StubHTTP.host { request in
            let path = request.url?.path ?? ""
            if path.hasSuffix("/archive/multipart") { return (200, startBody) }
            if path.hasSuffix("/multipart/parts") {
                let body = (try? JSONSerialization.jsonObject(with: request.httpBody ?? Data())) as? [String: Any]
                let parts = (body?["parts"] as? [[String: Any]]) ?? []
                return (200, Self.json(["parts": parts.map { part in
                    let number = part["part_number"] as? Int ?? 0
                    return [
                        "part_number": number,
                        "url": "https://\(s3Host)/p/f-1/A001.mov?partNumber=\(number)&uploadId=\(Self.uploadId)",
                        "headers": ["x-amz-checksum-sha256": part["checksum_sha256"] as? String ?? ""],
                    ]
                }]))
            }
            if path.hasSuffix("/multipart/complete") { return (200, completeBody) }
            if path.hasSuffix("/multipart/abort") { return (200, Self.json(["aborted": true])) }
            return (404, Self.json(["detail": "not stubbed"]))
        }
        let client = NUEDITBackendClient(session: StubHTTP.session())
        await client.use(NUEDITBackendSettings(baseURL: URL(string: "http://\(towerHost)"), agentKey: .value("k")))
        return Fixture(
            directory: directory, original: original, identity: identity, towerHost: towerHost, s3Host: s3Host,
            client: client, journal: ArchiveUploadJournal(directory: directory.appendingPathComponent("journal"))
        )
    }

    private func savedEntry(
        _ f: Fixture, checksum: String = "whole-file-sha", completedParts: [Int] = [], startedAt: Date = Date()
    ) async throws {
        var completed: [Int: NUEDITBackendClient.CompletedPart] = [:]
        for number in completedParts {
            let slice = Self.contents.subdata(in: (number - 1) * Self.partSize..<min(number * Self.partSize, Self.contents.count))
            completed[number] = .init(partNumber: number, etag: "\"etag-\(number)\"", checksumSHA256: Self.checksum(slice))
        }
        try await f.journal.save(.init(
            footageId: "f-1", checksum: checksum,
            plan: .init(key: "p/f-1/A001.mov", uploadId: "up-old", partSize: Self.partSize, partCount: 3),
            startedAt: startedAt, completed: completed
        ))
    }

    @Test func uploadsEveryPartSignedWithItsOwnChecksumThenCompletes() async throws {
        let f = try await fixture()
        defer { f.cleanUp() }
        #expect(await f.archive() == .archived(uri: Self.uri))

        let slices = [Data("0123".utf8), Data("4567".utf8), Data("89".utf8)]
        #expect(f.partPuts.map(\.body) == slices)
        #expect(f.partPuts.map { $0.headers["x-amz-checksum-sha256"] } == slices.map(Self.checksum))
        #expect(f.partPuts.allSatisfy { $0.headers["X-Agent-Key"] == nil })

        let parts = try #require(try f.towerBody(endingWith: "/multipart/complete")["parts"] as? [[String: Any]])
        #expect(parts.map { $0["part_number"] as? Int } == [1, 2, 3])
        #expect(parts.map { $0["etag"] as? String } == ["\"etag-1\"", "\"etag-2\"", "\"etag-3\""])
        #expect(try await f.journal.entry(footageId: "f-1") == nil)
    }

    @Test func resumesOnlyThePartsTheJournalLacks() async throws {
        let f = try await fixture()
        defer { f.cleanUp() }
        try await savedEntry(f, completedParts: [1])
        #expect(await f.archive() == .archived(uri: Self.uri))
        #expect(!f.towerPaths.contains { $0.hasSuffix("/archive/multipart") })
        #expect(f.partPuts.map(\.body) == [Data("4567".utf8), Data("89".utf8)])
        #expect(try f.towerBody(endingWith: "/multipart/complete")["upload_id"] as? String == "up-old")
    }

    @Test func aFailedPartKeepsTheFinishedPartsForTheNextPass() async throws {
        let f = try await fixture(failingPart: (2, 500, "InternalError"))
        defer { f.cleanUp() }
        guard case .failed = await f.archive() else {
            Issue.record("a rejected part must fail this pass")
            return
        }
        let entry = try #require(try await f.journal.entry(footageId: "f-1"))
        #expect(entry.completed.keys.sorted() == [1])
        #expect(!f.towerPaths.contains { $0.hasSuffix("/complete") || $0.hasSuffix("/abort") })
    }

    @Test func aRefusedCompleteAbortsAndForgetsTheUpload() async throws {
        let f = try await fixture(complete: ["footage_id": "f-1", "archived": false, "error": "S3 refused to complete the upload"])
        defer { f.cleanUp() }
        #expect(await f.archive() == .failed("S3 refused to complete the upload"))
        #expect(f.towerPaths.last?.hasSuffix("/multipart/abort") == true)
        #expect(try await f.journal.entry(footageId: "f-1") == nil)
    }

    @Test func anUploadS3NoLongerHoldsIsForgotten() async throws {
        let f = try await fixture(failingPart: (1, 404, "NoSuchUpload"))
        defer { f.cleanUp() }
        guard case .failed = await f.archive() else {
            Issue.record("a vanished upload must fail this pass")
            return
        }
        #expect(try await f.journal.entry(footageId: "f-1") == nil)
    }

    @Test(arguments: [
        ("other-bytes", 0.0),
        ("whole-file-sha", OriginalArchiver.journalMaxAge + 60),
    ])
    func aJournalForOtherBytesOrNearTheBucketDeadlineStartsOver(checksum: String, age: TimeInterval) async throws {
        let f = try await fixture()
        defer { f.cleanUp() }
        try await savedEntry(f, checksum: checksum, completedParts: [1], startedAt: Date().addingTimeInterval(-age))
        #expect(await f.archive() == .archived(uri: Self.uri))
        #expect(try f.towerBody(endingWith: "/multipart/abort")["upload_id"] as? String == "up-old")
        #expect(f.towerPaths.contains { $0.hasSuffix("/archive/multipart") })
        #expect(f.partPuts.count == 3)
    }

    @Test func aTowerThatAlreadyHoldsTheOriginalUploadsNothing() async throws {
        let f = try await fixture(start: ["skipped": true, "reason": "already archived", "archive_status": "archived"])
        defer { f.cleanUp() }
        #expect(await f.archive() == .alreadyArchived)
        #expect(f.partPuts.isEmpty)
        #expect(try await f.journal.entry(footageId: "f-1") == nil)
    }

    @Test func aPlanThatDoesNotCoverTheFileIsAbandoned() async throws {
        let f = try await fixture(start: [
            "footage_id": "f-1", "key": "k", "upload_id": Self.uploadId, "part_size": 4, "part_count": 2,
        ])
        defer { f.cleanUp() }
        #expect(await f.archive() == .failed("The tower's part plan doesn't match the original's size."))
        #expect(f.partPuts.isEmpty)
        #expect(f.towerPaths.last?.hasSuffix("/multipart/abort") == true)
    }

    @Test(arguments: [
        (4, 3, 10, true),
        (4, 3, 12, true),
        (4, 3, 8, false),
        (4, 2, 10, false),
        (0, 3, 10, false),
        (4, 0, 10, false),
        (Int.max, 2, 10, false),
    ])
    func aPlanCoversEveryByteExactlyOnce(partSize: Int, partCount: Int, size: Int, covers: Bool) {
        let plan = NUEDITBackendClient.MultipartPlan(key: "k", uploadId: "u", partSize: partSize, partCount: partCount)
        #expect(plan.covers(size) == covers)
    }
}
