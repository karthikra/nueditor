import Foundation

/// NUEditor reports nothing off-device. The facade is kept so the logging layer
/// and its call sites can keep passing diagnostic context; every entry point is a
/// no-op. See `Log` for the messages that stay local via OSLog.
enum Telemetry {
    typealias Payload = [String: Any]

    enum Level {
        case info
        case warning
        case error
        case fatal
    }

    static func breadcrumb(
        _ message: String,
        category: String = "app",
        level: Level = .info,
        data: Payload? = nil
    ) {}

    static func shortId(_ id: String) -> String {
        String(id.prefix(8))
    }

    static func setUser(id: String?) {}

    static func setExtra(value: Any?, key: String) {}

    static func logWarning(_ message: String, category: String, data: Payload? = nil) {}

    static func logError(_ message: String, category: String, data: Payload? = nil) {}

    static func logFault(_ message: String, category: String, data: Payload? = nil) {}
}
