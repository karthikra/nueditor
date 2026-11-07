import Foundation

/// Decoder for `application/vnd.amazon.eventstream`, the binary framing Bedrock streams in.
///
/// Frame: total length (4) · headers length (4) · prelude CRC (4) · headers · payload · message CRC (4),
/// big-endian, CRC-32 (IEEE) over everything before each checksum.
enum AWSEventStream {
    struct Message: Sendable, Equatable {
        let headers: [String: String]
        let payload: Data

        var messageType: String? { headers[":message-type"] }
        var eventType: String? { headers[":event-type"] }
        var exceptionType: String? { headers[":exception-type"] }
    }

    struct DecodingError: LocalizedError, Equatable {
        let reason: String
        var errorDescription: String? { "Bedrock stream is malformed: \(reason)." }
    }

    private static let preludeLength = 12
    private static let trailerLength = 4
    /// Bedrock chunks are small; a frame claiming more than this is corruption, not data.
    static let maximumMessageLength = 16 << 20

    /// Accumulates bytes and yields each complete frame.
    struct Decoder {
        private var buffer = Data()

        mutating func append(_ byte: UInt8) throws -> Message? {
            buffer.append(byte)
            return try nextMessage()
        }

        mutating func append(_ data: Data) throws -> [Message] {
            buffer.append(data)
            var messages: [Message] = []
            while let message = try nextMessage() { messages.append(message) }
            return messages
        }

        /// True when bytes of an unfinished frame remain — a stream that ends here was truncated.
        var hasPartialMessage: Bool { !buffer.isEmpty }

        private mutating func nextMessage() throws -> Message? {
            guard buffer.count >= AWSEventStream.preludeLength else { return nil }
            let bytes = [UInt8](buffer.prefix(AWSEventStream.preludeLength))
            let total = Int(AWSEventStream.uint32(bytes, at: 0))
            let headersLength = Int(AWSEventStream.uint32(bytes, at: 4))
            guard total >= AWSEventStream.preludeLength + AWSEventStream.trailerLength,
                  total <= AWSEventStream.maximumMessageLength,
                  headersLength <= total - AWSEventStream.preludeLength - AWSEventStream.trailerLength
            else { throw DecodingError(reason: "frame length \(total) is invalid") }
            guard AWSEventStream.crc32(bytes[0..<8]) == AWSEventStream.uint32(bytes, at: 8) else {
                throw DecodingError(reason: "prelude checksum mismatch")
            }
            guard buffer.count >= total else { return nil }

            let frame = [UInt8](buffer.prefix(total))
            buffer.removeFirst(total)
            guard AWSEventStream.crc32(frame[0..<(total - 4)]) == AWSEventStream.uint32(frame, at: total - 4) else {
                throw DecodingError(reason: "message checksum mismatch")
            }
            let headerStart = AWSEventStream.preludeLength
            let payloadStart = headerStart + headersLength
            let headers = try AWSEventStream.headers(frame[headerStart..<payloadStart])
            return Message(headers: headers, payload: Data(frame[payloadStart..<(total - 4)]))
        }
    }

    /// Reads typed headers; only string values are kept, the rest are skipped by their encoded width.
    static func headers(_ slice: ArraySlice<UInt8>) throws -> [String: String] {
        let bytes = Array(slice)
        var headers: [String: String] = [:]
        var i = 0
        func need(_ count: Int) throws {
            guard i + count <= bytes.count else { throw DecodingError(reason: "header runs past its frame") }
        }
        while i < bytes.count {
            try need(1)
            let nameLength = Int(bytes[i]); i += 1
            try need(nameLength + 1)
            let name = String(decoding: bytes[i..<(i + nameLength)], as: UTF8.self); i += nameLength
            let type = bytes[i]; i += 1
            switch type {
            case 0, 1: break
            case 2: try need(1); i += 1
            case 3: try need(2); i += 2
            case 4: try need(4); i += 4
            case 5, 8: try need(8); i += 8
            case 9: try need(16); i += 16
            case 6, 7:
                try need(2)
                let length = Int(bytes[i]) << 8 | Int(bytes[i + 1]); i += 2
                try need(length)
                if type == 7 { headers[name] = String(decoding: bytes[i..<(i + length)], as: UTF8.self) }
                i += length
            default:
                throw DecodingError(reason: "unknown header type \(type)")
            }
        }
        return headers
    }

    static func uint32(_ bytes: [UInt8], at offset: Int) -> UInt32 {
        bytes[offset..<(offset + 4)].reduce(0) { $0 << 8 | UInt32($1) }
    }

    private static let crcTable: [UInt32] = (0..<256).map { n in
        (0..<8).reduce(UInt32(n)) { c, _ in c & 1 == 1 ? 0xEDB8_8320 ^ (c >> 1) : c >> 1 }
    }

    static func crc32<C: Collection>(_ bytes: C) -> UInt32 where C.Element == UInt8 {
        ~bytes.reduce(~UInt32(0)) { crcTable[Int(($0 ^ UInt32($1)) & 0xFF)] ^ ($0 >> 8) }
    }
}
