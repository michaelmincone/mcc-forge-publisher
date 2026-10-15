import Foundation
import CryptoKit
import CZlib
#if REACH_STANDALONE_TESTS
// Command Line Tools can compile Foundation/CryptoKit without shipping XCTest.
// Compile this file together with the reader and error definitions for that host.
class XCTestCase {}
private func XCTAssertEqual<T: Equatable>(_ left: @autoclosure () throws -> T,
                                         _ right: @autoclosure () throws -> T,
                                         file: StaticString = #file, line: UInt = #line) {
    do {
        let actual = try left()
        let expected = try right()
        precondition(actual == expected, "Values differ", file: file, line: line)
    }
    catch { preconditionFailure("Unexpected error: \(error)", file: file, line: line) }
}
private func XCTAssertThrowsError<T>(_ expression: @autoclosure () throws -> T,
                                    file: StaticString = #file, line: UInt = #line) {
    do {
        _ = try expression()
        preconditionFailure("Expected the malformed map to be rejected", file: file, line: line)
    } catch {}
}
#else
import XCTest
@testable import MCCPublisherCore
#endif

final class ReachMapTests: XCTestCase {
    func testMetadataAndPhysicalTrailerArePreserved() throws {
        let trailer = Data([0x53, 0x49, 0x47, 0, 0xff])
        let data = fixture(trailer: trailer)
        let map = try ReachMapDocument(data: data, fileName: "synthetic.mvar")
        XCTAssertEqual(map.title, "Synthetic map 🚀")
        XCTAssertEqual(map.description, "A test fixture, without personal metadata.")
        XCTAssertEqual(map.mapID, 500)
        XCTAssertEqual(map.creatorXUID, "98765")
        XCTAssertEqual(map.modifierXUID, "12345")
        XCTAssertEqual(map.contentUID, "42")
        XCTAssertEqual(map.bodyVersion, 32)
        XCTAssertEqual(map.embeddedLength, 0x7329)
        XCTAssertEqual(map.trailingByteCount, trailer.count)
        XCTAssertEqual(map.bytes, data)
        XCTAssertEqual(map.sha256, SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined())
    }

    func testVersion31IsSupported() throws {
        XCTAssertEqual(try ReachMapDocument(data: fixture(version: 31), fileName: "old.mvar").bodyVersion, 31)
    }

    func testLoadKeepsSourceAndDoesNotRewriteFile() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("fixture.mvar")
        let data = fixture(trailer: Data([1, 2, 3]))
        try data.write(to: url)
        let map = try ReachMapDocument.load(from: url)
        XCTAssertEqual(map.sourceURL, url)
        XCTAssertEqual(map.fileName, "fixture.mvar")
        XCTAssertEqual(try Data(contentsOf: url), data)
    }

    func testHashTamperingIsRejected() {
        var data = fixture()
        data[0x2f0 + 0x24] ^= 1
        XCTAssertThrowsError(try ReachMapDocument(data: data, fileName: "tampered.mvar"))
    }

    func testTruncationAndOversizedPayloadAreRejected() {
        XCTAssertThrowsError(try ReachMapDocument(data: fixture().prefix(20), fileName: "short.mvar"))
        var data = fixture()
        setBE32(&data, at: 0x2f0 + 32, value: 0x7001)
        XCTAssertThrowsError(try ReachMapDocument(data: data, fileName: "length.mvar"))
        let payload = Data(body(version: 32).prefix(60))
        XCTAssertThrowsError(try ReachMapDocument(data: fixture(payload: payload), fileName: "body.mvar"))
    }

    func testDeclaredEnvelopeLengthAndMapIdentityAreValidated() {
        var data = fixture()
        setLE(&data, at: 0x30 + 0x14, value: UInt64(0x7328), count: 4)
        XCTAssertThrowsError(try ReachMapDocument(data: data, fileName: "wrong-length.mvar"))
        data = fixture()
        setLE(&data, at: 0x30 + 0x3c, value: 501, count: 4)
        XCTAssertThrowsError(try ReachMapDocument(data: data, fileName: "wrong-map.mvar"))
    }

    func testUnsupportedChunkVersionAndDuplicateMapAreRejected() {
        var data = fixture()
        data[0x2f0 + 9] = 30
        XCTAssertThrowsError(try ReachMapDocument(data: data, fileName: "version.mvar"))
        let variant = makeVariant(payload: Data(body(version: 32)))
        var duplicated = fixture()
        duplicated.insert(contentsOf: variant, at: 0x7318)
        XCTAssertThrowsError(try ReachMapDocument(data: duplicated, fileName: "duplicate.mvar"))
    }

    func testZlibWrapperExtractsMetadataButKeepsCompressedBytes() throws {
        let trailer = Data([0x4d, 0x45, 0x54, 0x41])
        let data = try compressedFixture(trailer: trailer)
        let map = try ReachMapDocument(data: data, fileName: "compressed.mvar")
        XCTAssertEqual(map.title, "Synthetic map 🚀")
        XCTAssertEqual(map.mapID, 500)
        XCTAssertEqual(map.bodyVersion, 32)
        XCTAssertEqual(map.bytes, data)
        XCTAssertEqual(map.embeddedLength, data.count - trailer.count)
        XCTAssertEqual(map.trailingByteCount, trailer.count)
    }

    func testCompressedSizeMismatchTruncationAndExpansionLimitAreRejected() throws {
        var data = try compressedFixture()
        setBE32(&data, at: 0x2f0 + 13, value: 0x7029)
        XCTAssertThrowsError(try ReachMapDocument(data: data, fileName: "size.mvar"))
        XCTAssertThrowsError(try ReachMapDocument(data: compressedFixture(truncated: true), fileName: "zlib.mvar"))
        data = try compressedFixture()
        setBE32(&data, at: 0x2f0 + 13, value: UInt32(ReachMapDocument.maximumFileSize + 1))
        XCTAssertThrowsError(try ReachMapDocument(data: data, fileName: "bomb.mvar"))
    }

    func testPhysicalFileSizeLimit() {
        XCTAssertThrowsError(try ReachMapDocument(data: Data(repeating: 0, count: ReachMapDocument.maximumFileSize + 1),
                                                fileName: "oversized.mvar"))
    }

    private func fixture(version: Int = 32, trailer: Data = Data(), payload: Data? = nil) -> Data {
        var data = start() + metadata() + makeVariant(payload: payload ?? Data(body(version: version)))
        data += end(offset: data.count)
        data += trailer
        return data
    }

    private func compressedFixture(trailer: Data = Data(), truncated: Bool = false) throws -> Data {
        let variant = makeVariant(payload: Data(body(version: 32)))
        var encoded = try zlib(variant)
        if truncated { encoded.removeLast() }
        var compressed = chunk("_cmp", size: 17 + encoded.count, major: 1, minor: 1)
        compressed[12] = 0
        setBE32(&compressed, at: 13, value: UInt32(variant.count))
        compressed.replaceSubrange(17 ..< compressed.count, with: encoded)
        var data = start() + metadata() + compressed
        data += end(offset: data.count)
        data += trailer
        return data
    }

    private func start() -> Data {
        var data = chunk("_blf", size: 48, major: 1, minor: 2)
        data[12] = 0xff
        data[13] = 0xfe
        return data
    }

    private func metadata() -> Data {
        var data = chunk("chdr", size: 704, major: 10, minor: 2)
        data[0x10] = 5
        setLE(&data, at: 0x14, value: 0x7329, count: 4)
        setLE(&data, at: 0x18, value: 42, count: 8)
        setLE(&data, at: 0x3c, value: 500, count: 4)
        setLE(&data, at: 0x50, value: 98765, count: 8)
        setLE(&data, at: 0x74, value: 12345, count: 8)
        for (offset, text) in [(0x90, "Synthetic map 🚀"), (0x190, "A test fixture, without personal metadata.")] {
            let string = text.data(using: .utf16LittleEndian)!
            data.replaceSubrange(offset ..< offset + string.count, with: string)
        }
        return data
    }

    private func makeVariant(payload: Data) -> Data {
        var data = chunk("mvar", size: 0x7028, major: 31, minor: 1)
        let count = UInt32(payload.count)
        var input = Data((0 ..< 4).map { UInt8(truncatingIfNeeded: count >> ($0 * 8)) })
        input += payload
        data.replaceSubrange(12 ..< 32, with: Array(Insecure.SHA1.hash(data: input)))
        setBE32(&data, at: 32, value: count)
        data.replaceSubrange(36 ..< 36 + payload.count, with: payload)
        return data
    }

    private func body(version: Int) -> [UInt8] {
        var writer = BitWriter()
        writer.write(6, 4) // Map content type is stored with a +1 bias.
        writer.write(0x7329, 32)
        writer.zeros(64 * 4)
        writer.zeros(3 + 3 + 3)
        writer.write(500, 32)
        writer.zeros(8)
        for _ in 0 ..< 2 { writer.zeros(128 + 8 + 1) }
        writer.zeros(16 + 16)
        writer.write(UInt64(version), 8)
        writer.zeros(64 + 9)
        writer.write(500, 32)
        writer.zeros(2)
        for value: Float in [-100, 100, -100, 100, -100, 100] { writer.write(UInt64(value.bitPattern), 32) }
        writer.write(100, 32)
        writer.zeros(32 + 9)
        if version >= 32 { writer.zeros(128) }
        writer.zeros(651)
        return writer.data
    }

    private func end(offset: Int) -> Data {
        var data = chunk("_eof", size: 17, major: 1, minor: 1)
        setBE32(&data, at: 12, value: UInt32(offset))
        return data
    }

    private func chunk(_ magic: String, size: Int, major: UInt16, minor: UInt16) -> Data {
        var data = Data(repeating: 0, count: size)
        data.replaceSubrange(0 ..< 4, with: magic.utf8)
        setBE32(&data, at: 4, value: UInt32(size))
        data[8] = UInt8(truncatingIfNeeded: major >> 8)
        data[9] = UInt8(truncatingIfNeeded: major)
        data[10] = UInt8(truncatingIfNeeded: minor >> 8)
        data[11] = UInt8(truncatingIfNeeded: minor)
        return data
    }

    private func setBE32(_ data: inout Data, at offset: Int, value: UInt32) {
        for index in 0 ..< 4 { data[offset + index] = UInt8(truncatingIfNeeded: value >> ((3 - index) * 8)) }
    }

    private func setLE(_ data: inout Data, at offset: Int, value: UInt64, count: Int) {
        for index in 0 ..< count { data[offset + index] = UInt8(truncatingIfNeeded: value >> (index * 8)) }
    }

    private func zlib(_ data: Data) throws -> Data {
        var count = compressBound(uLong(data.count))
        var output = [UInt8](repeating: 0, count: Int(count))
        let status = output.withUnsafeMutableBufferPointer { destination in
            data.withUnsafeBytes { source in
                compress2(destination.baseAddress, &count, source.bindMemory(to: UInt8.self).baseAddress,
                          uLong(data.count), Z_DEFAULT_COMPRESSION)
            }
        }
        guard status == Z_OK else { throw PublisherError.invalidMap("The synthetic zlib fixture failed.") }
        return Data(output.prefix(Int(count)))
    }

    private struct BitWriter {
        var data: [UInt8] = []
        var count = 0
        mutating func zeros(_ length: Int) { for _ in 0 ..< length { write(0, 1) } }
        mutating func write(_ value: UInt64, _ length: Int) {
            for shift in stride(from: length - 1, through: 0, by: -1) {
                if count % 8 == 0 { data.append(0) }
                data[count / 8] |= UInt8((value >> shift) & 1) << (7 - count % 8)
                count += 1
            }
        }
    }
}

#if REACH_STANDALONE_TESTS
@main
struct ReachMapStandaloneTests {
    static func main() throws {
        let tests = ReachMapTests()
        try tests.testMetadataAndPhysicalTrailerArePreserved()
        try tests.testVersion31IsSupported()
        try tests.testLoadKeepsSourceAndDoesNotRewriteFile()
        tests.testHashTamperingIsRejected()
        tests.testTruncationAndOversizedPayloadAreRejected()
        tests.testDeclaredEnvelopeLengthAndMapIdentityAreValidated()
        tests.testUnsupportedChunkVersionAndDuplicateMapAreRejected()
        try tests.testZlibWrapperExtractsMetadataButKeepsCompressedBytes()
        try tests.testCompressedSizeMismatchTruncationAndExpansionLimitAreRejected()
        tests.testPhysicalFileSizeLimit()
        print("ReachMapTests: 10 cases passed")
        // Optional local smoke inputs are read only and never copied into fixtures.
        for path in CommandLine.arguments.dropFirst() {
            let url = URL(fileURLWithPath: path)
            let original = try Data(contentsOf: url)
            let map = try ReachMapDocument.load(from: url)
            precondition(map.bytes == original)
            precondition(map.bytes.count == map.embeddedLength + map.trailingByteCount)
        }
        if CommandLine.arguments.count > 1 {
            print("Local map validation: \(CommandLine.arguments.count - 1) files passed without modification")
        }
    }
}
#endif
