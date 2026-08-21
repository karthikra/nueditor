import Foundation

/// Proxies on the internal disk, addressed by the original's checksum — so a re-import, a
/// remounted drive, or a second project referencing the same footage all find the same files.
///
/// Bounded by a byte budget with least-recently-used eviction. Eviction frees bytes and nothing
/// else: a clip whose proxy was evicted still plays (off its original) and regenerates on demand.
/// Proxies for footage in an open project are pinned so a big import can't evict what is on screen.
actor ProxyCache {
    static let shared = ProxyCache()

    static let defaultBudgetBytes: Int64 = 20 << 30   // 20 GB
    static let budgetDefaultsKey = "nueditProxyCacheBudgetBytes"

    private let directory: URL
    private let configuredBudget: Int64?
    private var pinned: Set<String> = []

    /// An explicit budget skips the defaults lookup — the shared cache reads the user's setting,
    /// anything else states its own size.
    init(directory: URL = ProxyCache.defaultDirectory, budgetBytes: Int64? = nil) {
        self.directory = directory
        self.configuredBudget = budgetBytes
    }

    static var defaultDirectory: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("\(Log.subsystem)/Proxies", isDirectory: true)
    }

    var budgetBytes: Int64 {
        if let configuredBudget { return configuredBudget }
        let stored = UserDefaults.standard.object(forKey: Self.budgetDefaultsKey) as? Int
        return stored.map(Int64.init) ?? Self.defaultBudgetBytes
    }

    nonisolated func url(checksum: String, kind: ProxyKind) -> URL {
        directory
            .appendingPathComponent(String(checksum.prefix(2)), isDirectory: true)
            .appendingPathComponent("\(checksum)-\(kind.rawValue).\(kind.fileExtension)")
    }

    /// The proxy if it is on disk, marking it as used so eviction takes something colder first.
    func existing(checksum: String, kind: ProxyKind) -> URL? {
        let url = url(checksum: checksum, kind: kind)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        touch(url)
        return url
    }

    /// A staging URL inside the cache: same volume as the destination, so installing is a rename.
    func stagingURL(checksum: String, kind: ProxyKind) throws -> URL {
        let url = url(checksum: checksum, kind: kind)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        return url.deletingLastPathComponent()
            .appendingPathComponent(".staging-\(UUID().uuidString)-\(url.lastPathComponent)")
    }

    /// Atomically installs a finished proxy. A half-written file never becomes a cache hit.
    @discardableResult
    func install(_ staged: URL, checksum: String, kind: ProxyKind) throws -> URL {
        let destination = url(checksum: checksum, kind: kind)
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        if FileManager.default.fileExists(atPath: destination.path) {
            _ = try FileManager.default.replaceItemAt(destination, withItemAt: staged)
        } else {
            try FileManager.default.moveItem(at: staged, to: destination)
        }
        touch(destination)
        return destination
    }

    /// Footage in an open project: never evicted, however cold it looks.
    func pin(checksums: Set<String>) { pinned.formUnion(checksums) }
    func unpin(checksums: Set<String>) { pinned.subtract(checksums) }

    func totalBytes() -> Int64 {
        entries().reduce(0) { $0 + $1.size }
    }

    /// Deletes coldest-first until the cache fits its budget. Pinned proxies and staging files
    /// are never candidates.
    @discardableResult
    func evictToBudget() -> Int64 {
        let budget = budgetBytes
        var entries = self.entries()
        var total = entries.reduce(0) { $0 + $1.size }
        guard total > budget else { return 0 }
        entries.sort { $0.accessed < $1.accessed }
        var freed: Int64 = 0
        for entry in entries where total > budget {
            guard !pinned.contains(entry.checksum) else { continue }
            guard (try? FileManager.default.removeItem(at: entry.url)) != nil else { continue }
            total -= entry.size
            freed += entry.size
        }
        if freed > 0 {
            Log.project.info("proxy cache evicted bytes=\(freed) remaining=\(total) budget=\(budget)")
        }
        return freed
    }

    func removeAll() {
        try? FileManager.default.removeItem(at: directory)
    }

    private struct Entry {
        let url: URL
        let checksum: String
        let size: Int64
        let accessed: Date
    }

    private func entries() -> [Entry] {
        let keys: [URLResourceKey] = [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey]
        guard let walker = FileManager.default.enumerator(
            at: directory, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]
        ) else { return [] }
        var entries: [Entry] = []
        for case let url as URL in walker {
            guard let values = try? url.resourceValues(forKeys: Set(keys)),
                  values.isRegularFile == true,
                  let size = values.fileSize else { continue }
            let name = url.deletingPathExtension().lastPathComponent
            guard !name.hasPrefix(".staging-"),
                  let checksum = name.split(separator: "-").first.map(String.init) else { continue }
            entries.append(Entry(
                url: url, checksum: checksum, size: Int64(size),
                accessed: values.contentModificationDate ?? .distantPast
            ))
        }
        return entries
    }

    /// Modification date doubles as last-used: a cache hit is a use.
    private func touch(_ url: URL) {
        try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: url.path)
    }
}
