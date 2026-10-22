import Foundation
import CryptoKit
import CZlib

public enum VariantKind: String, Codable, CaseIterable, Sendable {
    case map, gametype
    public var fileExtension: String { self == .map ? "mvar" : "bin" }
    public var catalogContentType: String { self == .map ? "MapVariant" : "GameVariant" }
    public var label: String { self == .map ? "Map" : "Gametype" }
    public init?(catalogContentType: String) {
        switch catalogContentType {
        case "MapVariant": self = .map
        case "GameVariant": self = .gametype
        default: return nil
        }
    }
}

/// Fresh uploads support Reach. Catalog downloads use their own cross-game validator.
public enum ReachVariantDocument: Sendable {
    case map(ReachMapDocument)
    case gametype(ReachGameVariantDocument)

    public static func load(from url: URL) throws -> Self {
        switch url.pathExtension.lowercased() {
        case "mvar": return .map(try ReachMapDocument.load(from: url))
        case "bin", "game": return .gametype(try ReachGameVariantDocument.load(from: url))
        default: throw PublisherError.invalidMap("Choose a Reach .mvar map or compiled .bin gametype.")
        }
    }
    public var kind: VariantKind { if case .map = self { return .map }; return .gametype }
    public var title: String { switch self { case .map(let v): return v.title; case .gametype(let v): return v.title } }
    public var description: String { switch self { case .map(let v): return v.description; case .gametype(let v): return v.description } }
    public var bytes: Data { switch self { case .map(let v): return v.bytes; case .gametype(let v): return v.bytes } }
    public var embeddedLength: Int { switch self { case .map(let v): return v.embeddedLength; case .gametype(let v): return v.embeddedLength } }
    public var trailingByteCount: Int { bytes.count - embeddedLength }
    public var sourceURL: URL { switch self { case .map(let v): return v.sourceURL; case .gametype(let v): return v.sourceURL } }
    public var fileName: String { switch self { case .map(let v): return v.fileName; case .gametype(let v): return v.fileName } }
    public var sha256: String { switch self { case .map(let v): return v.sha256; case .gametype(let v): return v.sha256 } }
}

/// Reads the ReachVariantTool BLF/MPVR layout without rewriting source bytes.
/// Validates the salted SHA-1 and bounded header, not the whole Megalo program.
public struct ReachGameVariantDocument: Sendable {
    public static let maximumFileSize = ReachMapDocument.maximumFileSize
    public let sourceURL: URL
    public let fileName: String
    public let bytes: Data
    public let title: String
    public let description: String
    public let creatorXUID: String
    public let modifierXUID: String
    public let creatorTimestamp: UInt64
    public let editorTimestamp: UInt64
    public let contentUID: String
    public let engineType: Int
    public let engineCategory: Int
    public let headerEngineCategory: Int
    public let bodyVersion: Int
    public let embeddedLength: Int
    public let sha256: String
    public var trailingByteCount: Int { bytes.count - embeddedLength }

    public static func load(from url: URL) throws -> Self {
        guard url.isFileURL else { throw invalid("Choose a local compiled gametype.") }
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard let size = attributes[.size] as? NSNumber, size.uint64Value <= UInt64(maximumFileSize) else {
            throw invalid("The gametype exceeds the 16 MB size limit.")
        }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        return try Self(data: handle.read(upToCount: maximumFileSize + 1) ?? Data(), fileName: url.lastPathComponent, sourceURL: url)
    }

    public init(data: Data, fileName: String, sourceURL: URL = URL(fileURLWithPath: "/gametype.bin")) throws {
        guard data.count <= Self.maximumFileSize else { throw Self.invalid("The gametype exceeds the 16 MB size limit.") }
        var state = ScanState()
        let end = try Self.scan([UInt8](data), outer: true, depth: 0, state: &state)
        guard let header = state.header, let body = state.variant, header.count >= 0x2c0,
              Self.be16(header, 8) == 10, Self.be16(header, 10) == 2, header[0x10] == 6 else {
            throw Self.invalid("The file must contain a Reach game-variant content header and MPVR payload.")
        }
        let declared = Int(Self.le32(header, 0x14))
        guard declared > 0, declared <= Self.maximumFileSize, state.compressed || declared == end else {
            throw Self.invalid("The gametype's declared BLF length does not match its envelope.")
        }
        let metadata = try Self.inspectBody(body)
        self.sourceURL = sourceURL; self.fileName = fileName; self.bytes = data
        self.title = metadata.title; self.description = metadata.description
        self.creatorXUID = metadata.author; self.modifierXUID = metadata.editor
        self.creatorTimestamp = metadata.createdAt; self.editorTimestamp = metadata.editedAt
        self.contentUID = metadata.uid; self.engineType = metadata.engine
        self.engineCategory = metadata.category; self.headerEngineCategory = metadata.headerCategory; self.bodyVersion = Int(Self.be16(body, 8))
        self.embeddedLength = end
        self.sha256 = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private struct ScanState { var header: [UInt8]?; var variant: [UInt8]?; var compressed = false; var expanded = 0 }
    private static func scan(_ bytes: [UInt8], outer: Bool, depth: Int, state: inout ScanState) throws -> Int {
        guard depth <= 4 else { throw invalid("The gametype's compressed chunks are nested too deeply.") }
        var offset = 0
        while offset < bytes.count {
            guard bytes.count - offset >= 12 else { throw invalid("A gametype BLF header is truncated.") }
            let magic = String(bytes: bytes[offset..<offset + 4], encoding: .ascii) ?? ""
            let length = Int(be32(bytes, offset + 4))
            guard length >= 12, length <= bytes.count - offset else { throw invalid("A gametype BLF chunk has an invalid length.") }
            let chunk = Array(bytes[offset..<offset + length])
            if outer && offset == 0 && magic != "_blf" { throw invalid("The gametype does not begin with a BLF envelope.") }
            switch magic {
            case "_blf":
                guard offset == 0, length >= 48, be16(chunk, 8) == 1, be16(chunk, 10) == 2 else { throw invalid("The gametype BLF envelope is unsupported.") }
            case "chdr":
                guard state.header == nil else { throw invalid("Duplicate gametype content headers are ambiguous.") }
                state.header = chunk
            case "mpvr":
                guard state.variant == nil, [50, 54].contains(Int(be16(chunk, 8))), be16(chunk, 10) == 1 else {
                    throw invalid("Only Reach MPVR versions 50.1 and 54.1 are supported for upload.")
                }
                state.variant = chunk
            case "mvar", "mapv", "gvar": throw invalid("This is not a supported compiled Reach MPVR gametype.")
            case "_cmp":
                guard length >= 17, be16(chunk, 8) == 1, be16(chunk, 10) == 1, chunk[12] == 0 else {
                    throw invalid("The gametype's compressed BLF wrapper is unsupported.")
                }
                let expandedLength = Int(be32(chunk, 13))
                guard expandedLength > 0, expandedLength <= maximumFileSize - state.expanded else { throw invalid("The expanded gametype exceeds the 16 MB limit.") }
                state.expanded += expandedLength; state.compressed = true
                var expanded = [UInt8](repeating: 0, count: expandedLength)
                var outputCount = uLongf(expandedLength), inputCount = uLong(length - 17)
                let input = Array(chunk[17...])
                let result = expanded.withUnsafeMutableBufferPointer { out in input.withUnsafeBufferPointer { src in
                    uncompress2(out.baseAddress, &outputCount, src.baseAddress, &inputCount)
                } }
                guard result == Z_OK, outputCount == expandedLength, inputCount == input.count else { throw invalid("The compressed gametype is truncated or corrupt.") }
                _ = try scan(expanded, outer: false, depth: depth + 1, state: &state)
            case "_eof":
                guard length >= 17, be16(chunk, 8) == 1, be16(chunk, 10) == 1, outer || offset + length == bytes.count else {
                    throw invalid("The gametype BLF end marker is invalid.")
                }
                return offset + length
            default: break
            }
            offset += length
        }
        guard !outer else { throw invalid("The gametype BLF end marker is missing.") }
        return offset
    }

    private static func inspectBody(_ chunk: [UInt8]) throws -> (title: String, description: String, author: String, editor: String, uid: String, engine: Int, category: Int, headerCategory: Int, createdAt: UInt64, editedAt: UInt64) {
        guard chunk.count >= 41 else { throw invalid("The MPVR payload is truncated.") }
        // RVT writes salt + big-endian length + body, with a little-endian
        // multiplayer length field. Shipped MCC variants use big-endian length
        // + body without salt. Match a bounded candidate's actual checksum.
        let engine = Int(chunk[40] >> 4)
        guard [1, 2, 4].contains(engine) else { throw invalid("This Reach gametype engine is unsupported.") }
        let salt = Data([0xed,0xd4,0x30,0x09,0x66,0x6d,0x5c,0x4a,0x5c,0x36,0x57,0xfa,0xb4,0x0e,0x02,0x2f,0x53,0x5a,0xc6,0xc9,0xee,0x47,0x1f,0x01,0xf1,0xa4,0x47,0x56,0xb7,0x71,0x4f,0x1c,0x36,0xec])
        var verifiedPayload: [UInt8]?
        for length in Set([Int(be32(chunk, 36)), Int(le32(chunk, 36))]) where length > 0 && length <= chunk.count - 40 {
            let payload = Array(chunk[40..<40 + length])
            let lengthBytes = Data((0..<4).map { UInt8(truncatingIfNeeded: UInt32(length) >> (24 - $0 * 8)) })
            let ordinary = lengthBytes + Data(payload)
            let salted = salt + ordinary
            if Array(Insecure.SHA1.hash(data: salted)) == Array(chunk[12..<32]) ||
                (length == Int(be32(chunk, 36)) && Array(Insecure.SHA1.hash(data: ordinary)) == Array(chunk[12..<32])) {
                verifiedPayload = payload; break
            }
        }
        guard let payload = verifiedPayload else { throw invalid("The gametype's SHA-1 integrity checksum or body length does not match.") }
        var bits = Bits(payload)
        _ = try bits.read(4)
        if engine != 4 {
            let encodingVersion = try bits.read(32)
            guard encodingVersion == 0x6a || encodingVersion == 0x6b else {
                throw invalid("The Reach multiplayer encoding version is unsupported.")
            }
            try bits.skip(32) // engine version
        }
        guard try bits.read(4) == 7 else { throw invalid("The MPVR body is not a game variant.") }
        try bits.skip(32)
        let uid = try bits.read(64)
        try bits.skip(64 * 3)
        let activity = Int(try bits.read(3)) - 1
        let gameMode = Int(try bits.read(3))
        try bits.skip(3 + 32)
        let headerCategory = Int(try bits.read(8))
        let createdAt = try bits.read(64); let author = try bits.read(64); _ = try bits.string(width: 8, limit: 16); try bits.skip(1)
        let editedAt = try bits.read(64); let editor = try bits.read(64); _ = try bits.string(width: 8, limit: 16); try bits.skip(1)
        let title = try bits.string(width: 16, limit: 128)
        let description = try bits.string(width: 16, limit: 128)
        try bits.skip(8) // UGC engine-icon byte, distinct from the multiplayer category.
        if activity == 2 { try bits.skip(16) }
        if gameMode == 1 { try bits.skip(8 + 2 + 2 + 8 + 32) }
        else if gameMode == 2 { try bits.skip(2 + 32) }
        let category: Int
        if engine == 4 { category = -1 }
        else { category = try bits.multiplayerCategory() }
        return (title, description, String(author), String(editor), String(uid), engine, category, headerCategory, createdAt, editedAt)
    }

    private struct Bits {
        let bytes: [UInt8]; var position = 0
        init(_ bytes: [UInt8]) { self.bytes = bytes }
        mutating func read(_ count: Int) throws -> UInt64 {
            guard count >= 0, count <= 64, count <= bytes.count * 8 - position else { throw ReachGameVariantDocument.invalid("The gametype bitstream is truncated.") }
            var value: UInt64 = 0
            for _ in 0..<count { value = value << 1 | UInt64((bytes[position / 8] >> (7 - position % 8)) & 1); position += 1 }
            return value
        }
        mutating func skip(_ count: Int) throws {
            guard count >= 0, count <= bytes.count * 8 - position else { throw ReachGameVariantDocument.invalid("The gametype bitstream is truncated.") }
            position += count
        }
        // Bounded traversal of the fields preceding the multiplayer category,
        // matching RVT's GameVariantDataMultiplayer::read. The native MCC getter
        // reads this field, rather than the duplicated UGC header category.
        mutating func multiplayerCategory() throws -> Int {
            try skip(1) // isBuiltIn
            try skip(33 + 55); try playerTraits() // general + respawn
            try skip(8 + 6); try playerTraits() // social + map base traits
            try skip(16)
            for _ in 0..<3 { try playerTraits() }
            try skip(21 + 8) // powerup durations + team options
            for _ in 0..<8 {
                try skip(4)
                try stringTable(maxCount: 1, maxBytes: 0x20, offsetWidth: 5, sizeWidth: 6)
                try skip(4 + 1 + 32 * 3 + 5)
            }
            try skip(2)
            for _ in 0..<30 {
                try skip(1)
                if try read(1) == 0 { try skip(7) }
                try skip(8 * 3 + 4)
            }
            let traitCount = Int(try read(5))
            guard traitCount <= 16 else { throw ReachGameVariantDocument.invalid("The gametype contains too many script traits.") }
            for _ in 0..<traitCount { try skip(14); try playerTraits() }
            let optionCount = Int(try read(5))
            guard optionCount <= 16 else { throw ReachGameVariantDocument.invalid("The gametype contains too many script options.") }
            for _ in 0..<optionCount {
                try skip(14)
                if try read(1) != 0 { try skip(40) }
                else {
                    try skip(3)
                    let values = Int(try read(4))
                    guard values > 0 && values <= 8 else { throw ReachGameVariantDocument.invalid("A gametype script option has an invalid value count.") }
                    try skip(values * 24 + 3)
                }
            }
            try stringTable(maxCount: 112, maxBytes: 0x4c00, offsetWidth: 15, sizeWidth: 15)
            try skip(7) // optional generic-name index, stored with an offset
            try stringTable(maxCount: 1, maxBytes: 0x180, offsetWidth: 9, sizeWidth: 9)
            try stringTable(maxCount: 1, maxBytes: 0xc00, offsetWidth: 12, sizeWidth: 12)
            try stringTable(maxCount: 1, maxBytes: 0x180, offsetWidth: 9, sizeWidth: 9)
            try skip(5) // multiplayer engine icon, offset by one
            return Int(try read(5)) - 1
        }
        mutating func playerTraits() throws {
            try skip(31 + 48 + 15)
            if try read(1) != 0 { try skip(9) }
            try skip(14 + 8)
        }
        mutating func stringTable(maxCount: Int, maxBytes: Int, offsetWidth: Int, sizeWidth: Int) throws {
            let countWidth = maxCount == 1 ? 1 : 7
            let count = Int(try read(countWidth))
            guard count <= maxCount else { throw ReachGameVariantDocument.invalid("A gametype string table has too many entries.") }
            guard count > 0 else { return }
            var offsets: [Int] = []
            for _ in 0..<(count * 12) {
                if try read(1) != 0 { offsets.append(Int(try read(offsetWidth))) }
            }
            let expanded = Int(try read(sizeWidth))
            let compressed = try read(1) != 0
            let stored = compressed ? Int(try read(sizeWidth)) : expanded
            guard expanded <= maxBytes, stored <= maxBytes + 4, offsets.allSatisfy({ $0 < expanded }),
                  !compressed || stored >= 4 else { throw ReachGameVariantDocument.invalid("A gametype string table has invalid bounds.") }
            try skip(stored * 8)
        }
        mutating func string(width: Int, limit: Int) throws -> String {
            var units: [UInt16] = []
            for _ in 0..<limit { let value = UInt16(try read(width)); if value == 0 { break }; units.append(value) }
            if width == 8 { return String(decoding: units.map { UInt8(truncatingIfNeeded: $0) }, as: UTF8.self) }
            let bytes = units.flatMap { [UInt8(truncatingIfNeeded: $0), UInt8(truncatingIfNeeded: $0 >> 8)] }
            guard let string = String(data: Data(bytes), encoding: .utf16LittleEndian) else { throw ReachGameVariantDocument.invalid("The gametype text contains invalid UTF-16.") }
            return string
        }
    }
    private static func be16(_ b: [UInt8], _ o: Int) -> UInt16 { UInt16(b[o]) << 8 | UInt16(b[o + 1]) }
    private static func be32(_ b: [UInt8], _ o: Int) -> UInt32 { (0..<4).reduce(0) { $0 << 8 | UInt32(b[o + $1]) } }
    private static func le32(_ b: [UInt8], _ o: Int) -> UInt32 { (0..<4).reduce(0) { $0 | UInt32(b[o + $1]) << ($1 * 8) } }
    private static func invalid(_ message: String) -> PublisherError { .invalidMap(message) }
}
