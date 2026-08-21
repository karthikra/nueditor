import Foundation

/// Builds a `multipart/form-data` body on disk rather than in memory: an ingest upload carries a
/// video proxy and a WAV, and a few hundred megabytes of Data is not a body, it is a memory spike.
/// The finished file is handed to `URLSession.upload(fromFile:)`, which streams it.
enum MultipartFormData {
    struct FilePart: Sendable {
        let name: String
        let filename: String
        let contentType: String
        let fileURL: URL
    }

    struct Body: Sendable {
        let fileURL: URL
        let contentType: String
    }

    /// 1 MB — big enough that copying a proxy is a few hundred reads, small enough to stay flat.
    private static let chunkSize = 1 << 20

    /// Writes the body to `directory` and returns it. Blocking file I/O: call it off the main actor.
    /// The caller owns the returned file and must delete it on success, failure, and cancellation.
    static func write(
        fields: [String: String],
        files: [FilePart],
        in directory: URL,
        boundary: String = "nueditor.\(UUID().uuidString)"
    ) throws -> Body {
        let bodyURL = directory.appendingPathComponent("multipart-\(UUID().uuidString).tmp")
        guard FileManager.default.createFile(atPath: bodyURL.path, contents: nil) else {
            throw BackendError.transport("Could not stage the upload body at \(bodyURL.path).")
        }
        let handle = try FileHandle(forWritingTo: bodyURL)
        var succeeded = false
        defer {
            try? handle.close()
            if !succeeded { try? FileManager.default.removeItem(at: bodyURL) }
        }

        for (name, value) in fields.sorted(by: { $0.key < $1.key }) {
            try handle.write(contentsOf: Data("--\(boundary)\r\n".utf8))
            try handle.write(contentsOf: Data("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n".utf8))
            try handle.write(contentsOf: Data(value.utf8))
            try handle.write(contentsOf: Data("\r\n".utf8))
        }

        for file in files {
            try Task.checkCancellation()
            let source = try FileHandle(forReadingFrom: file.fileURL)
            defer { try? source.close() }
            try handle.write(contentsOf: Data("--\(boundary)\r\n".utf8))
            try handle.write(contentsOf: Data(
                "Content-Disposition: form-data; name=\"\(file.name)\"; filename=\"\(file.filename)\"\r\n".utf8
            ))
            try handle.write(contentsOf: Data("Content-Type: \(file.contentType)\r\n\r\n".utf8))
            while let chunk = try source.read(upToCount: chunkSize), !chunk.isEmpty {
                try Task.checkCancellation()
                try handle.write(contentsOf: chunk)
            }
            try handle.write(contentsOf: Data("\r\n".utf8))
        }

        try handle.write(contentsOf: Data("--\(boundary)--\r\n".utf8))
        succeeded = true
        return Body(fileURL: bodyURL, contentType: "multipart/form-data; boundary=\(boundary)")
    }
}
