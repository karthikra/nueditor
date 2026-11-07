import Foundation
import Synchronization

/// Serves canned responses per host, so each test owns a unique host and suites stay parallel-safe.
final class StubHTTP: URLProtocol, @unchecked Sendable {
    struct Recorded: Sendable {
        let method: String
        let url: URL
        let headers: [String: String]
        let body: Data?
    }

    typealias Handler = @Sendable (URLRequest) -> (status: Int, body: Data)

    private static let routes = Mutex<[String: (handler: Handler, log: [Recorded])]>([:])

    /// Registers a fresh host; every request to it is answered by `handler` and recorded.
    static func host(_ handler: @escaping Handler) -> String {
        register(host: "\(UUID().uuidString.lowercased()).stub.test", handler)
    }

    /// For a client that builds its own host; the caller makes `host` unique to its test.
    @discardableResult
    static func register(host: String, _ handler: @escaping Handler) -> String {
        routes.withLock { $0[host] = (handler, []) }
        return host
    }

    static func requests(to host: String) -> [Recorded] {
        routes.withLock { $0[host]?.log ?? [] }
    }

    static func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubHTTP.self]
        return URLSession(configuration: configuration)
    }

    override class func canInit(with request: URLRequest) -> Bool {
        guard let host = request.url?.host else { return false }
        return routes.withLock { $0[host] != nil }
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url, let host = url.host,
              let handler = Self.routes.withLock({ $0[host]?.handler }) else {
            client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL))
            return
        }
        let recorded = Recorded(
            method: request.httpMethod ?? "GET", url: url,
            headers: request.allHTTPHeaderFields ?? [:], body: request.httpBody ?? Self.drain(request.httpBodyStream)
        )
        Self.routes.withLock { $0[host]?.log.append(recorded) }
        let (status, body) = handler(request)
        let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    private static func drain(_ stream: InputStream?) -> Data? {
        guard let stream else { return nil }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count > 0 else { break }
            data.append(buffer, count: count)
        }
        return data
    }
}
