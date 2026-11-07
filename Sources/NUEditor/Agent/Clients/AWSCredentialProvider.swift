import Foundation

/// Resolves AWS credentials through the AWS CLI's own provider chain — environment, named
/// profile, SSO, assumed role — so nothing is stored by this app and no key is ever typed into it.
/// Credentials live in memory only, until they expire or Bedrock rejects them.
actor AWSCredentialProvider {
    static let shared = AWSCredentialProvider()

    struct Resolved: Sendable {
        let credentials: AWSSigV4.Credentials
        let expiration: Date?
    }

    enum Failure: LocalizedError, Equatable {
        case cliNotFound
        case cliFailed(String)
        case timedOut
        case unreadable

        var errorDescription: String? {
            switch self {
            case .cliNotFound:
                "AWS CLI not found. Install it, then run `aws configure` or `aws sso login`."
            case .cliFailed(let message):
                message
            case .timedOut:
                "AWS CLI did not return credentials in time."
            case .unreadable:
                "AWS CLI returned credentials this build can't read."
            }
        }
    }

    /// A GUI app inherits a minimal PATH, so the usual install locations are probed directly.
    static let cliSearchPaths = ["/opt/homebrew/bin/aws", "/usr/local/bin/aws", "/usr/bin/aws"]
    static let refreshMargin: TimeInterval = 300
    static let timeout: Duration = .seconds(20)

    typealias Resolver = @Sendable (String) async throws -> Resolved

    private let resolve: Resolver
    private var cache: [String: Resolved] = [:]
    private var inFlight: [String: Task<Resolved, Error>] = [:]

    init(resolve: @escaping Resolver = { try await AWSCredentialProvider.resolveWithCLI(profile: $0) }) {
        self.resolve = resolve
    }

    /// An empty profile defers to the CLI's default chain (`AWS_PROFILE`, then `default`).
    func credentials(profile: String) async throws -> AWSSigV4.Credentials {
        if let cached = cache[profile], !Self.needsRefresh(cached) { return cached.credentials }
        if let task = inFlight[profile] { return try await task.value.credentials }
        let resolve = self.resolve
        let task = Task { try await resolve(profile) }
        inFlight[profile] = task
        defer { inFlight[profile] = nil }
        let resolved = try await task.value
        cache[profile] = resolved
        return resolved.credentials
    }

    /// Bedrock rejected what we hold; the next call resolves afresh.
    func invalidate(profile: String) {
        cache[profile] = nil
    }

    static func needsRefresh(_ resolved: Resolved, now: Date = Date()) -> Bool {
        guard let expiration = resolved.expiration else { return false }
        return expiration.timeIntervalSince(now) < refreshMargin
    }

    /// Parses `aws configure export-credentials --format process` output.
    static func parse(_ data: Data) throws -> Resolved {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let accessKey = object["AccessKeyId"] as? String, !accessKey.isEmpty,
              let secret = object["SecretAccessKey"] as? String, !secret.isEmpty
        else { throw Failure.unreadable }
        let token = (object["SessionToken"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        let expiration = (object["Expiration"] as? String).flatMap { ISO8601DateFormatter().date(from: $0) }
        return Resolved(
            credentials: AWSSigV4.Credentials(accessKeyId: accessKey, secretAccessKey: secret, sessionToken: token),
            expiration: expiration
        )
    }

    @concurrent
    private static func resolveWithCLI(profile: String) async throws -> Resolved {
        guard let cli = cliSearchPaths.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
            throw Failure.cliNotFound
        }
        var arguments = ["configure", "export-credentials", "--format", "process"]
        if !profile.isEmpty { arguments += ["--profile", profile] }
        let (status, output, errorOutput) = try await run(URL(fileURLWithPath: cli), arguments: arguments)
        guard status == 0 else {
            let message = String(decoding: errorOutput, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            throw Failure.cliFailed(message.isEmpty ? "AWS CLI exited with status \(status)." : String(message.prefix(400)))
        }
        return try parse(output)
    }

    /// Runs a short-lived process to completion without blocking a thread on it.
    private static func run(_ executable: URL, arguments: [String]) async throws -> (Int32, Data, Data) {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        let output = Pipe(), errors = Pipe()
        process.standardOutput = output
        process.standardError = errors
        process.standardInput = FileHandle.nullDevice

        let exited = AsyncStream<Int32> { continuation in
            process.terminationHandler = { continuation.yield($0.terminationStatus); continuation.finish() }
        }
        try process.run()
        let watchdog = Task {
            try await Task.sleep(for: timeout)
            process.terminate()
        }
        defer { watchdog.cancel() }

        // Output is a few hundred bytes, well under a pipe buffer, so reading after exit is safe.
        var status: Int32 = -1
        for await code in exited { status = code }
        if process.terminationReason == .uncaughtSignal { throw Failure.timedOut }
        return (
            status,
            output.fileHandleForReading.readDataToEndOfFile(),
            errors.fileHandleForReading.readDataToEndOfFile()
        )
    }
}
