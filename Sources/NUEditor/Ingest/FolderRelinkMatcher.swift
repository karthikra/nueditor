import Foundation

/// Matches offline clips to files in a folder the user points at.
///
/// A clip with a content identity matches only the file holding its bytes, whatever that file is
/// called or wherever it sits in the folder: camera names like `C0001.MP4` repeat on every card, so
/// a name proves nothing. Candidates are narrowed by exact size before any hashing. A clip with no
/// identity — imported before checksums existed — falls back to its filename.
enum FolderRelinkMatcher {
    struct ScannedFile: Sendable, Equatable {
        let url: URL
        let size: Int
    }

    struct OfflineClip: Sendable {
        let id: String
        let filename: String
        let identity: FootageIdentity?
    }

    /// Regular files under `folder`, recursively, in a stable order. Always off the main actor.
    @concurrent
    static func scan(_ folder: URL) async -> [ScannedFile] {
        let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey]
        guard let walker = FileManager.default.enumerator(
            at: folder, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return [] }
        var files: [ScannedFile] = []
        while let url = walker.nextObject() as? URL {
            if files.count.isMultiple(of: 256), Task.isCancelled { return [] }
            guard let values = try? url.resourceValues(forKeys: Set(keys)), values.isRegularFile == true,
                  let size = values.fileSize else { continue }
            files.append(ScannedFile(url: url, size: size))
        }
        return files.sorted { $0.url.path < $1.url.path }
    }

    /// Clip id → the file it relinks to. Clips with no acceptable file are absent.
    @concurrent
    static func match(
        _ clips: [OfflineClip],
        in files: [ScannedFile],
        checksum: @Sendable (URL) async throws -> String = { try await FootageProbe.checksum(of: $0) }
    ) async -> [String: URL] {
        var bySize: [Int: [ScannedFile]] = [:]
        var byName: [String: URL] = [:]
        for file in files {
            bySize[file.size, default: []].append(file)
            let name = file.url.lastPathComponent.lowercased()
            if byName[name] == nil { byName[name] = file.url }
        }

        var hashes: [URL: String] = [:]
        var matches: [String: URL] = [:]
        for clip in clips {
            guard !Task.isCancelled else { return [:] }
            guard let identity = clip.identity else {
                if let url = byName[clip.filename.lowercased()] { matches[clip.id] = url }
                continue
            }
            let name = clip.filename.lowercased()
            let candidates = (bySize[identity.fileSizeBytes] ?? [])
                .sorted { ($0.url.lastPathComponent.lowercased() == name ? 0 : 1) < ($1.url.lastPathComponent.lowercased() == name ? 0 : 1) }
            for candidate in candidates {
                guard !Task.isCancelled else { return [:] }
                let hash: String
                if let cached = hashes[candidate.url] {
                    hash = cached
                } else {
                    guard let computed = try? await checksum(candidate.url) else { continue }
                    hashes[candidate.url] = computed
                    hash = computed
                }
                if hash == identity.checksum {
                    matches[clip.id] = candidate.url
                    break
                }
            }
        }
        return matches
    }
}
