import Foundation
import CryptoKit
import CZlib

#if canImport(XCTest) && !GAME_VARIANT_STANDALONE_TESTS
import XCTest
@testable import MCCPublisherCore
final class GameVariantTests: XCTestCase {
    func testReachGametypeMetadataAndSourcePreservation() throws { try GameVariantCases.reader() }
    func testMalformedWrongGameAndTamperedGametypeRejection() throws { try GameVariantCases.invalid() }
    func testGametypeDownloadKindAndAtomicBinExport() throws { try GameVariantCases.download() }
    func testGametypeNamesAndSearch() throws { try GameVariantCases.search() }
    func testFreshNativeGametypeMetadataUsesBodyCategory() throws { try GameVariantCases.metadata() }
}
#endif

#if canImport(XCTest) || GAME_VARIANT_STANDALONE_TESTS
private enum GameVariantCases {
    struct Failure: Error, CustomStringConvertible { let description: String }
    static func check(_ condition: Bool, _ message: String) throws { if !condition { throw Failure(description: message) } }
    static func rejects(_ message: String, _ work: () throws -> Void) throws {
        do { try work() } catch { return }; throw Failure(description: message)
    }
    static func reader() throws {
        let bytes = fixture() + Data([0xff, 0x33])
        let game = try ReachGameVariantDocument(data: bytes, fileName: "fixture.bin")
        try check(game.title == "Synthetic 星 🚀" && game.description == "A compiled test gametype", "Bit-packed title/description did not survive decoding")
        try check(game.engineType == 2 && game.engineCategory == 1 && game.creatorXUID == "12345" && game.modifierXUID == "67890", "Gametype category or author identities were decoded incorrectly")
        try check(game.bytes == bytes && game.embeddedLength == 21289 && game.trailingByteCount == 2 && game.bodyVersion == 54, "Source bytes, BLF boundary or version were changed")
        let value = ReachVariantDocument.gametype(game)
        try check(value.kind == .gametype && value.title == game.title && value.bytes == bytes, "Generic upload document lost gametype identity")
        let native = try ReachGameVariantDocument(data: fixture(salted: false), fileName: "native.bin")
        try check(native.title == game.title && native.engineCategory == game.engineCategory, "Shipped MCC unsalted big-endian checksum framing was rejected")
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("mcc-gametype-\(UUID())")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("fixture.bin"); try bytes.write(to: url)
        let loaded = try ReachVariantDocument.load(from: url)
        try check(loaded.kind == .gametype && loaded.sourceURL == url && (try Data(contentsOf: url)) == bytes, "File loading changed the compiled source")
    }
    static func invalid() throws {
        var changed = fixture(); changed[0x318 + 120] ^= 1
        try rejects("Tampered MPVR hash was accepted") { _ = try ReachGameVariantDocument(data: changed, fileName: "fixture.bin") }
        changed = fixture(); changed[0x30 + 0x10] = 5
        try rejects("A map header was accepted as a game variant") { _ = try ReachGameVariantDocument(data: changed, fileName: "fixture.bin") }
        changed = fixture(); changed[0x2f0 + 9] = 137
        try rejects("Halo 2 Anniversary MPVR was accepted for fresh Reach upload") { _ = try ReachGameVariantDocument(data: changed, fileName: "fixture.bin") }
        try rejects("Truncated compiled gametype was accepted") { _ = try ReachGameVariantDocument(data: fixture().dropLast(1), fileName: "fixture.bin") }
        try rejects("A text source file was accepted as a compiled gametype") { _ = try ReachGameVariantDocument(data: Data("declare global.number[0] with network priority high".utf8), fileName: "script.megalo") }
        changed = fixture(); put(&changed, 0x30 + 0x14, 21288, count: 4, little: true)
        try rejects("Invalid physical length was accepted") { _ = try ReachGameVariantDocument(data: changed, fileName: "fixture.bin") }
    }
    static func download() throws {
        let bytes = fixture() + Data([0xfa, 0xfb, 0xfc])
        let game = try FileShareDownload(data: bytes, itemID: "test", kind: .gametype)
        try check(game.data == bytes && game.kind == .gametype, "Gametype export rewrote source provenance")
        try rejects("Gametype was accepted as a map download") { _ = try FileShareDownload(data: bytes, itemID: "test", kind: .map) }
        var map = fixture(); map.replaceSubrange(0x2f0..<0x2f4, with: "mvar".utf8)
        try rejects("Map was accepted as a gametype download") { _ = try FileShareDownload(data: map, itemID: "test", kind: .gametype) }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("mcc-bin-export-\(UUID())")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("test.bin")
        try game.save(to: url)
        try check(try Data(contentsOf: url) == bytes, "Atomic .bin save changed received bytes")
        try rejects("Gametype saved with map extension") { try game.save(to: dir.appendingPathComponent("wrong.mvar")) }
        let mixed = chunk("_blf", 48, 1, minor: 2) + chunk("mpvr", 60, 54) + chunk("mvar", 60, 31) + chunk("_eof", 17, 1)
        try rejects("Mixed map/game payload was accepted") { _ = try FileShareDownload(data: mixed, itemID: "test", kind: .gametype) }
    }
    static func search() throws {
        let game = FileShareItem(id: "00000000-0000-0000-0000-000000000001", title: "../Café: Slayer.bin", description: "Arena combat", game: "Halo: Reach", accountEntityID: "OWNER", accountXUID: "1234", kind: .gametype)
        try check(game.suggestedFilename.hasSuffix(".bin") && !game.suggestedFilename.contains(":"), "Gametype name did not use a safe .bin extension")
        try check(game.matches(search: "CAFE Reach") && game.matches(search: "arena gametype") && !game.matches(search: "Slayer Halo4"), "Search did not match every case/diacritic-insensitive term across metadata")
        try check(VariantKind(catalogContentType: "GameVariant") == .gametype && VariantKind(catalogContentType: "Film") == nil, "Unknown catalog content was misclassified")
    }
    static func metadata() throws {
        let account = SignedInAccount(xuid: "123456", gamertag: "Synthetic", sessionTicket: "FAKE_TICKET", entityToken: "FAKE_ENTITY_TOKEN", entityId: "FAKE_ENTITY", expiresAt: .distantFuture)
        // The native accessor reads the multiplayer category. A duplicated UGC
        // header with a different category must not misclassify the upload.
        let bytes = fixture(category: 7, headerCategory: 16) + Data(repeating: 0, count: 24)
        let game = try ReachGameVariantDocument(data: bytes, fileName: "fixture.bin")
        try check(game.engineCategory == 7 && game.headerEngineCategory == 16, "The duplicated UGC header overrode the native multiplayer category")
        let plan = try FreshVariantMetadata.makePlan(variant: .gametype(game), account: account)
        let metadata = plan.metadata
        let p = metadata["DisplayProperties"]
        try check(plan.kind == .gametype && plan.title == game.title && plan.payload == Data(bytes.prefix(game.embeddedLength)), "Gametype upload lost its type or sent local padding")
        try check(metadata["ContentType"].string == "GameVariant" && p["GameEngine"].string == "6" && p["GameCategory"].string == "5", "Native game subtype classification/category is wrong")
        try check(p["BuiltInMapId"] == .null && p["IsForgeVariant"] == .null && p["FileAdditionalMetadata"] == .null, "Fresh metadata invented map, Forge or provenance fields")
        try check(metadata["Tags"] == .array([.string("HaloReach"), .string("GameCategory_Infection"), .string("PC")]), "Gametype tags differ from native game/category/platform descriptor")
        try check(p["CreatorId"].string == account.xuid && p["AuthorXuid"].string == "12345" && p["EditorXuid"].string == "67890", "Uploader identity replaced source author/editor identity")
        try check(UUID(uuidString: plan.fileID) != nil && plan.fileID == plan.fileID.lowercased() && p["FileName"].string == plan.fileID, "Fresh gametype filename is not a native UUID")
        let config = try MCCServiceConfiguration(upload: URL(string: "https://mcc-production.azurefd.net/test/upload")!, permission: URL(string: "https://mcc-production.azurefd.net/test/permission")!, source: "synthetic")
        let request = try plan.request(credentials: account, services: config)
        let suffix = try metadata.encoded()
        try check(request.body == plan.payload + suffix && request.headers["ContentLength"] == String(plan.payload.count) && request.headers["MetadataLength"] == String(suffix.count), "Gametype request length/framing differs from native upload contract")
        try check(game.bytes == bytes, "Metadata construction modified the compiled source")
        let unknown = try ReachGameVariantDocument(data: fixture(category: 20), fileName: "unknown.bin")
        try rejects("Unknown native category was silently reclassified") { _ = try FreshGameMetadata.makePlan(gametype: unknown, account: account) }
        let trailer = try ReachGameVariantDocument(data: fixture() + Data([1]), fileName: "signed.bin")
        try rejects("Unpreservable provenance was silently dropped from fresh gametype upload") { _ = try FreshGameMetadata.makePlan(gametype: trailer, account: account) }
        for (raw, expected) in [(0,0),(1,1),(2,2),(3,3),(4,4),(5,15),(6,16),(7,5),(8,14),(9,23),(10,21),(11,24),(12,7),(13,22),(16,24),(30,26)] {
            let value = try ReachGameVariantDocument(data: fixture(category: raw), fileName: "category.bin")
            try check(try FreshGameMetadata.gameCategory(for: value).id == expected, "Raw Reach category did not match the native MCC conversion")
        }
    }
    struct Writer {
        var bytes: [UInt8] = []; var bit = 0
        mutating func write(_ value: UInt64, _ width: Int) {
            for index in (0..<width).reversed() {
                if bit % 8 == 0 { bytes.append(0) }
                if value >> index & 1 != 0 { bytes[bit / 8] |= 1 << (7 - bit % 8) }
                bit += 1
            }
        }
        mutating func string(_ value: String, width: Int) {
            for unit in value.utf16 { write(UInt64(unit), width) }; write(0, width)
        }
    }
    static func fixture(salted: Bool = true, category: Int = 1, headerCategory: Int? = nil) -> Data {
        var bits = Writer()
        bits.write(2, 4); bits.write(0x6b, 32); bits.write(0, 32)
        bits.write(7, 4); bits.write(21289, 32); bits.write(42, 64)
        for _ in 0..<3 { bits.write(0, 64) }
        bits.write(1, 3); bits.write(3, 3); bits.write(2, 3); bits.write(0xffffffff, 32); bits.write(UInt64(headerCategory ?? category), 8)
        for id: UInt64 in [12345, 67890] { bits.write(id == 12345 ? 1_700_000_000 : 1_700_000_001, 64); bits.write(id, 64); bits.string("Tester", width: 8); bits.write(1, 1) }
        bits.string("Synthetic 星 🚀", width: 16); bits.string("A compiled test gametype", width: 16)
        bits.write(0, 8) // UGC engine icon
        bits.write(0, 1) // isBuiltIn
        bits.write(0, 33 + 55)
        func traits(_ b: inout Writer) { b.write(0, 31 + 48 + 15); b.write(0, 1); b.write(0, 14 + 8) }
        traits(&bits)
        bits.write(0, 8 + 6); traits(&bits); bits.write(0, 16)
        for _ in 0..<3 { traits(&bits) }
        bits.write(0, 21 + 8)
        for _ in 0..<8 { bits.write(0, 4 + 1 + 4 + 1 + 32 * 3 + 5) }
        bits.write(0, 2)
        for _ in 0..<30 { bits.write(0, 1); bits.write(1, 1); bits.write(0, 8 * 3 + 4) }
        bits.write(0, 5 + 5) // no script traits/options
        bits.write(0, 7 + 7) // no script strings + generic-name index
        bits.write(0, 1 + 1 + 1) // no localized name/description/category
        bits.write(0, 5); bits.write(UInt64(category + 1), 5)
        let payload = Data(bits.bytes)
        var hash = salted ? Data([0xed,0xd4,0x30,0x09,0x66,0x6d,0x5c,0x4a,0x5c,0x36,0x57,0xfa,0xb4,0x0e,0x02,0x2f,0x53,0x5a,0xc6,0xc9,0xee,0x47,0x1f,0x01,0xf1,0xa4,0x47,0x56,0xb7,0x71,0x4f,0x1c,0x36,0xec]) : Data()
        var length = Data(repeating: 0, count: 4); put(&length, 0, payload.count, count: 4)
        hash += length; hash += payload
        var header = chunk("chdr", 704, 10, minor: 2); header[0x10] = 6; put(&header, 0x14, 21289, count: 4, little: true)
        var body = chunk("mpvr", 20520, 54)
        body.replaceSubrange(12..<32, with: Data(Insecure.SHA1.hash(data: hash)))
        put(&body, 36, payload.count, count: 4, little: salted); body.replaceSubrange(40..<40 + payload.count, with: payload)
        return chunk("_blf", 48, 1, minor: 2) + header + body + chunk("_eof", 17, 1)
    }
    static func chunk(_ name: String, _ size: Int, _ version: Int, minor: Int = 1) -> Data {
        var value = Data(repeating: 0, count: size); value.replaceSubrange(0..<4, with: name.utf8)
        put(&value, 4, size, count: 4); put(&value, 8, version, count: 2); put(&value, 10, minor, count: 2)
        return value
    }
    static func put(_ data: inout Data, _ offset: Int, _ value: Int, count: Int, little: Bool = false) {
        for i in 0..<count { data[offset + i] = UInt8(truncatingIfNeeded: value >> ((little ? i : count - i - 1) * 8)) }
    }
}
#if GAME_VARIANT_STANDALONE_TESTS
@main struct GameVariantStandaloneTests {
    static func main() throws {
        try GameVariantCases.reader(); try GameVariantCases.invalid(); try GameVariantCases.download(); try GameVariantCases.search(); try GameVariantCases.metadata()
        print("Game variant tests: 5 cases passed; native category and upload framing, salted Reach integrity, metadata, wrong-game/type/truncation rejection, exact .bin save, and metadata search; no live network or remote writes.")
    }
}
#endif
#endif
