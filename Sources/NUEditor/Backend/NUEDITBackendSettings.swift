import Foundation

/// Where the NUEDIT tower is and how to reach it.
///
/// Base URL resolution, in order:
/// 1. an explicit override typed in Settings;
/// 2. `api_url` in `~/.nuhandoff/hub.toml` — the same per-machine file the nuhub address comes
///    from, so the tower is written down once per machine rather than in five configs;
/// 3. nothing — the backend is unconfigured and every call fails loudly rather than guessing a host.
struct NUEDITBackendSettings: Sendable, Equatable {
    var baseURL: URL?
    /// Bearer token. The tower is unauthenticated on the tailnet today; this exists so adding auth
    /// is a settings change rather than a rebuild. Move to the Keychain if it ever holds a real secret.
    var token: String?

    var isConfigured: Bool { baseURL != nil }
}

enum NUEDITBackendSettingsStore {
    static let baseURLOverrideKey = "nueditBackendBaseURL"
    static let tokenKey = "nueditBackendToken"

    /// Reads the override and the SSOT file. Touches the filesystem — call it off the main actor.
    @concurrent
    static func resolve(
        defaults: UserDefaults = .standard,
        hubTOML: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".nuhandoff/hub.toml")
    ) async -> NUEDITBackendSettings {
        let override = defaults.string(forKey: baseURLOverrideKey)?.trimmingCharacters(in: .whitespaces)
        let token = defaults.string(forKey: tokenKey)?.trimmingCharacters(in: .whitespaces)
        let raw = (override?.isEmpty == false ? override : nil) ?? value(forKey: "api_url", in: hubTOML)
        return NUEDITBackendSettings(
            baseURL: raw.flatMap(normalizedBaseURL),
            token: (token?.isEmpty == false) ? token : nil
        )
    }

    /// A trailing slash or an accidental `/api/v1` suffix must not produce a double-pathed URL.
    static func normalizedBaseURL(_ raw: String) -> URL? {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        while text.hasSuffix("/") { text.removeLast() }
        if text.hasSuffix("/api/v1") { text.removeLast("/api/v1".count) }
        guard let url = URL(string: text), url.scheme != nil, url.host != nil else { return nil }
        return url
    }

    /// Minimal reader for the flat `key = "value"` lines hub.toml uses.
    static func value(forKey key: String, in file: URL) -> String? {
        guard let text = try? String(contentsOf: file, encoding: .utf8) else { return nil }
        for line in text.split(separator: "\n") {
            let parts = line.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2, parts[0].trimmingCharacters(in: .whitespaces) == key else { continue }
            let value = parts[1].trimmingCharacters(in: .whitespaces)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            return value.isEmpty ? nil : value
        }
        return nil
    }
}
