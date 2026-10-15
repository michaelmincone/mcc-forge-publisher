import Foundation
import CryptoKit
import CZlib

/// Inspects a Reach map without rewriting its BLF envelope or appended metadata.
public struct ReachMapDocument: Sendable {
    public static let maximumFileSize = 16 * 1024 * 1024

    public let sourceURL: URL
    public let fileName: String
    public let bytes: Data
    public let title: String
    public let description: String
    public let mapID: UInt32
    public let creatorXUID: String
    public let modifierXUID: String
    public let contentUID: String
    public let bodyVersion: Int
    public let embeddedLength: Int
    public let sha256: String
    public let trailingByteCount: Int

    public static func load(from url: URL) throws -> ReachMapDocument {
        guard url.isFileURL else { throw invalid("Select a local map file.") }
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard let size = attributes[.size] as? NSNumber,
              size.uint64Value <= UInt64(maximumFileSize) else {
            throw invalid("The map exceeds the 16 MB size limit.")
        }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let data = try handle.read(upToCount: maximumFileSize + 1) ?? Data()
        return try ReachMapDocument(data: data, fileName: url.lastPathComponent, sourceURL: url)
    }

    public init(data: Data, fileName: String,
                sourceURL: URL = URL(fileURLWithPath: "/map.mvar")) throws {
        guard data.count <= Self.maximumFileSize else {
            throw Self.invalid("The map exceeds the 16 MB size limit.")
        }
        var state = ScanState()
        let physicalEnd = try Self.scan(Array(data), depth: 0, state: &state)
        guard let header = state.header, let variant = state.variant else {
            throw Self.invalid("The file must contain Reach chdr and mvar chunks.")
        }
        guard header.count >= 0x290 else { throw Self.invalid("The content header is truncated.") }
        guard Self.be16(header, 8) == 10, Self.be16(header, 10) == 2 else {
            throw Self.invalid("This content-header version is unsupported.")
        }
        guard header[0x10] == 5 else { throw Self.invalid("The file is not a Reach map variant.") }
        let declaredLength = Int(Self.le32(header, 0x14))
        if !state.compressed, declaredLength != physicalEnd {
            throw Self.invalid("The content header's BLF length does not match the envelope.")
        }
        guard declaredLength > 0, declaredLength <= Self.maximumFileSize else {
            throw Self.invalid("The content header's BLF length is invalid.")
        }
        let headerMapID = Self.le32(header, 0x3c)
        let body = try Self.inspectBody(variant, mapID: headerMapID)

        self.sourceURL = sourceURL
        self.fileName = fileName
        self.bytes = data
        self.title = try Self.utf16(header, at: 0x90)
        self.description = try Self.utf16(header, at: 0x190)
        self.mapID = headerMapID
        self.creatorXUID = String(Self.le64(header, 0x50))
        self.modifierXUID = String(Self.le64(header, 0x74))
        self.contentUID = String(Self.le64(header, 0x18))
        self.bodyVersion = body.version
        self.embeddedLength = physicalEnd
        self.trailingByteCount = data.count - physicalEnd
        self.sha256 = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private struct ScanState {
        var header: [UInt8]?
        var variant: [UInt8]?
        var compressed = false
        var expandedBytes = 0
    }

    /// The outer EOF ends the embedded BLF, leaving physical trailers untouched.
    private static func scan(_ input: [UInt8], depth: Int, state: inout ScanState) throws -> Int {
        guard depth <= 4 else { throw invalid("Compressed chunks are nested too deeply.") }
        var offset = 0
        var sawStart = false
        while offset < input.count {
            guard input.count - offset >= 12 else { throw invalid("A BLF chunk header is truncated.") }
            let magic = String(bytes: input[offset ..< offset + 4], encoding: .ascii) ?? ""
            let length = Int(be32(input, offset + 4))
            guard length >= 12, length <= input.count - offset else {
                throw invalid("A BLF chunk length exceeds the available bytes.")
            }
            let chunk = Array(input[offset ..< offset + length])
            if depth == 0, offset == 0, magic != "_blf" {
                throw invalid("The file does not begin with a BLF envelope.")
            }
            switch magic {
            case "_blf":
                guard offset == 0, !sawStart, length >= 0x30,
                      be16(chunk, 8) == 1, be16(chunk, 10) == 2 else {
                    throw invalid("The BLF start chunk is invalid or unsupported.")
                }
                sawStart = true
            case "chdr":
                guard state.header == nil else { throw invalid("Duplicate content headers are ambiguous.") }
                state.header = chunk
            case "mvar":
                guard state.variant == nil else { throw invalid("Duplicate map-variant chunks are ambiguous.") }
                guard be16(chunk, 8) == 31, be16(chunk, 10) == 1 else {
                    throw invalid("Only Reach mvar chunk version 31.1 is supported.")
                }
                state.variant = chunk
            case "_cmp":
                guard be16(chunk, 8) == 1, be16(chunk, 10) == 1, length >= 17,
                      chunk[12] == 0 else { throw invalid("The compressed BLF wrapper is unsupported.") }
                let expandedLength = Int(be32(chunk, 13))
                guard expandedLength > 0,
                      expandedLength <= maximumFileSize - state.expandedBytes else {
                    throw invalid("Expanded chunks exceed the 16 MB size limit.")
                }
                state.compressed = true
                state.expandedBytes += expandedLength
                let expanded = try expand(Array(chunk[17...]), expected: expandedLength)
                _ = try scan(expanded, depth: depth + 1, state: &state)
            case "_eof":
                guard length >= 17, be16(chunk, 8) == 1, be16(chunk, 10) == 1 else {
                    throw invalid("The BLF end chunk is invalid or unsupported.")
                }
                let end = offset + length
                if depth != 0, end != input.count {
                    throw invalid("A compressed chunk contains data after its BLF end marker.")
                }
                return end
            default:
                // Preserve other chunks, such as provenance, without interpreting them.
                break
            }
            offset += length
        }
        if depth == 0 { throw invalid("The BLF end chunk is missing.") }
        return offset
    }

    private static func expand(_ input: [UInt8], expected: Int) throws -> [UInt8] {
        var output = [UInt8](repeating: 0, count: expected)
        var outputLength = uLongf(expected)
        var inputLength = uLong(input.count)
        let result = output.withUnsafeMutableBufferPointer { destination in
            input.withUnsafeBufferPointer { source in
                uncompress2(destination.baseAddress, &outputLength, source.baseAddress, &inputLength)
            }
        }
        guard result == Z_OK, outputLength == expected, inputLength == input.count else {
            throw invalid("The zlib payload is truncated or its declared size is incorrect.")
        }
        return output
    }

    private static func inspectBody(_ chunk: [UInt8], mapID: UInt32) throws -> (version: Int, length: Int) {
        guard chunk.count >= 36 else { throw invalid("The mvar header is truncated.") }
        let length = Int(be32(chunk, 32))
        guard length > 0, length <= 0x7000, length <= chunk.count - 36 else {
            throw invalid("The mvar payload length is invalid.")
        }
        let payload = Array(chunk[36 ..< 36 + length])
        let count = UInt32(length)
        var hashInput = Data((0 ..< 4).map { UInt8(truncatingIfNeeded: count >> ($0 * 8)) })
        hashInput.append(contentsOf: payload)
        guard Array(Insecure.SHA1.hash(data: hashInput)) == Array(chunk[12 ..< 32]) else {
            throw invalid("The map's SHA-1 integrity checksum does not match.")
        }

        var bits = Bits(payload)
        let contentType = Int(try bits.read(4)) - 1
        guard contentType == 5 else { throw invalid("The mvar body is not a map variant.") }
        try bits.skip(32 + 64 * 4)
        let activity = Int(try bits.read(3)) - 1
        let gameMode = Int(try bits.read(3))
        try bits.skip(3)
        let bodyHeaderMapID = UInt32(try bits.read(32))
        try bits.skip(8)
        for _ in 0 ..< 2 {
            try bits.skip(128)
            try bits.string(width: 8, limit: 16)
            try bits.skip(1)
        }
        try bits.string(width: 16, limit: 128)
        try bits.string(width: 16, limit: 128)
        if activity == 2 { try bits.skip(16) }
        if gameMode == 1 { try bits.skip(8 + 2 + 2 + 8 + 32) }
        else if gameMode == 2 { try bits.skip(2 + 32) }
        let version = Int(try bits.read(8))
        guard version == 31 || version == 32 else { throw invalid("Only Reach map body versions 31 and 32 are supported.") }
        try bits.skip(64)
        let quotas = try bits.read(9)
        let bodyMapID = UInt32(try bits.read(32))
        guard quotas <= 256, bodyHeaderMapID == mapID, bodyMapID == mapID else {
            throw invalid("The map identity or quota count is inconsistent.")
        }
        try bits.skip(2)
        for _ in 0 ..< 6 {
            let value = Float(bitPattern: UInt32(try bits.read(32)))
            guard value.isFinite else { throw invalid("The map world bounds are not finite.") }
        }
        try bits.skip(64)
        let labels = Int(try bits.read(9))
        guard labels <= 256 else { throw invalid("The Forge label count exceeds its supported range.") }
        for _ in 0 ..< labels {
            if try bits.read(1) != 0 { try bits.skip(12) }
        }
        if labels > 0 {
            let bufferLength = Int(try bits.read(13))
            let compressed = try bits.read(1) != 0
            let encodedLength = compressed ? Int(try bits.read(13)) : bufferLength
            try bits.skip(encodedLength * 8)
        }
        if version >= 32 { try bits.skip(128) }
        // Even an empty map writes one occupancy bit for each of 651 slots.
        guard bits.remaining >= 651 else { throw invalid("The object-slot bitstream is truncated.") }
        return (version, length)
    }

    private struct Bits {
        let bytes: [UInt8]
        var position = 0
        init(_ bytes: [UInt8]) { self.bytes = bytes }
        var remaining: Int { bytes.count * 8 - position }
        mutating func read(_ count: Int) throws -> UInt64 {
            guard count >= 0, count <= 64, count <= remaining else {
                throw ReachMapDocument.invalid("The map bitstream is truncated.")
            }
            var value: UInt64 = 0
            for _ in 0 ..< count {
                value = value << 1 | UInt64((bytes[position / 8] >> (7 - position % 8)) & 1)
                position += 1
            }
            return value
        }
        mutating func skip(_ count: Int) throws {
            guard count >= 0, count <= remaining else { throw ReachMapDocument.invalid("The map bitstream is truncated.") }
            position += count
        }
        mutating func string(width: Int, limit: Int) throws {
            for _ in 0 ..< limit { if try read(width) == 0 { return } }
        }
    }

    private static func utf16(_ input: [UInt8], at offset: Int) throws -> String {
        var end = offset
        while end < offset + 256, le16(input, end) != 0 { end += 2 }
        guard let string = String(data: Data(input[offset ..< end]), encoding: .utf16LittleEndian) else {
            throw invalid("The map text contains invalid UTF-16 metadata.")
        }
        return string
    }
    private static func le16(_ bytes: [UInt8], _ offset: Int) -> UInt16 {
        UInt16(bytes[offset]) | UInt16(bytes[offset + 1]) << 8
    }
    private static func be16(_ bytes: [UInt8], _ offset: Int) -> UInt16 {
        UInt16(bytes[offset]) << 8 | UInt16(bytes[offset + 1])
    }
    private static func be32(_ bytes: [UInt8], _ offset: Int) -> UInt32 {
        (0 ..< 4).reduce(0) { $0 << 8 | UInt32(bytes[offset + $1]) }
    }
    private static func le32(_ bytes: [UInt8], _ offset: Int) -> UInt32 {
        (0 ..< 4).reduce(0) { $0 | UInt32(bytes[offset + $1]) << ($1 * 8) }
    }
    private static func le64(_ bytes: [UInt8], _ offset: Int) -> UInt64 {
        (0 ..< 8).reduce(0) { $0 | UInt64(bytes[offset + $1]) << ($1 * 8) }
    }
    private static func invalid(_ message: String) -> PublisherError { .invalidMap(message) }
}
