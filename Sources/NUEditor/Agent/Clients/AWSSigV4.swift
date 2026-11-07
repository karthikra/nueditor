import CryptoKit
import Foundation

/// AWS Signature Version 4 for a single request with an in-memory body.
enum AWSSigV4 {
    struct Credentials: Sendable, Equatable {
        let accessKeyId: String
        let secretAccessKey: String
        let sessionToken: String?
    }

    /// Adds `x-amz-date`, `x-amz-content-sha256`, the session token, and `Authorization`.
    /// The path must already be percent-encoded; non-S3 services sign it encoded a second time.
    static func sign(
        _ request: inout URLRequest,
        body: Data,
        credentials: Credentials,
        region: String,
        service: String,
        date: Date = Date()
    ) {
        guard let url = request.url, let host = url.host else { return }
        let (amzDate, dateStamp) = timestamps(date)
        let payloadHash = hex(SHA256.hash(data: body))

        request.setValue(amzDate, forHTTPHeaderField: "x-amz-date")
        request.setValue(payloadHash, forHTTPHeaderField: "x-amz-content-sha256")
        if let token = credentials.sessionToken {
            request.setValue(token, forHTTPHeaderField: "x-amz-security-token")
        }

        var headers: [String: String] = ["host": url.port.map { "\(host):\($0)" } ?? host]
        for (name, value) in request.allHTTPHeaderFields ?? [:] {
            headers[name.lowercased()] = value.trimmingCharacters(in: .whitespaces)
        }
        let names = headers.keys.sorted()
        let signedHeaders = names.joined(separator: ";")
        let canonicalHeaders = names.map { "\($0):\(headers[$0]!)\n" }.joined()

        let encodedPath = URLComponents(url: url, resolvingAgainstBaseURL: false)?.percentEncodedPath ?? "/"
        let canonicalRequest = [
            request.httpMethod ?? "GET",
            canonicalURI(encodedPath),
            canonicalQuery(url),
            canonicalHeaders,
            signedHeaders,
            payloadHash,
        ].joined(separator: "\n")

        let scope = "\(dateStamp)/\(region)/\(service)/aws4_request"
        let stringToSign = [
            "AWS4-HMAC-SHA256", amzDate, scope, hex(SHA256.hash(data: Data(canonicalRequest.utf8))),
        ].joined(separator: "\n")

        var key = SymmetricKey(data: Data("AWS4\(credentials.secretAccessKey)".utf8))
        for part in [dateStamp, region, service, "aws4_request"] {
            key = SymmetricKey(data: Data(HMAC<SHA256>.authenticationCode(for: Data(part.utf8), using: key)))
        }
        let signature = hex(HMAC<SHA256>.authenticationCode(for: Data(stringToSign.utf8), using: key))

        request.setValue(
            "AWS4-HMAC-SHA256 Credential=\(credentials.accessKeyId)/\(scope), SignedHeaders=\(signedHeaders), Signature=\(signature)",
            forHTTPHeaderField: "Authorization"
        )
    }

    /// RFC 3986 unreserved characters pass through; everything else is `%XX`, uppercase.
    static func uriEncode(_ text: String) -> String {
        var allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789")
        allowed.insert(charactersIn: "-._~")
        return text.addingPercentEncoding(withAllowedCharacters: allowed) ?? text
    }

    static func canonicalURI(_ encodedPath: String) -> String {
        guard !encodedPath.isEmpty else { return "/" }
        return encodedPath.split(separator: "/", omittingEmptySubsequences: false)
            .map { uriEncode(String($0)) }
            .joined(separator: "/")
    }

    private static func canonicalQuery(_ url: URL) -> String {
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        return items
            .map { (uriEncode($0.name), uriEncode($0.value ?? "")) }
            .sorted { $0 < $1 }
            .map { "\($0.0)=\($0.1)" }
            .joined(separator: "&")
    }

    private static func timestamps(_ date: Date) -> (amzDate: String, dateStamp: String) {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let c = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        let day = String(format: "%04d%02d%02d", c.year!, c.month!, c.day!)
        return (day + String(format: "T%02d%02d%02dZ", c.hour!, c.minute!, c.second!), day)
    }

    private static func hex<D: Sequence>(_ digest: D) -> String where D.Element == UInt8 {
        digest.map { String(format: "%02x", $0) }.joined()
    }
}
