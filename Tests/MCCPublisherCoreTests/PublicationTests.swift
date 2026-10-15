import Foundation
import CryptoKit

#if canImport(XCTest) && !PUBLICATION_STANDALONE_TESTS
import XCTest
@testable import MCCPublisherCore

final class PublicationTests: XCTestCase {
    func testNativeUploadFramingAndUnicodeMetadata() throws { try PublicationCases.framing() }
    func testAuthenticationHeadersAndAccountBinding() throws { try PublicationCases.credentials() }
    func testReachScenarioIDsUseMCCCatalogValues() throws { try PublicationCases.catalog() }
    func testUnknownMapScenarioBlocksPublication() throws { try PublicationCases.unknownMap() }
    func testNonzeroAndSignedTrailersBlockFreshPublication() throws { try PublicationCases.provenance() }
    func testDiscoveryUsesRecoveredAuthoritiesSchema() throws { try PublicationCases.discovery() }
    func testDiscoveryRequiresHTTPSAuthoritySchemeAndPort() throws { try PublicationCases.authorityTransport() }
    func testMaliciousEndpointsCannotReceiveCredentials() throws { try PublicationCases.endpoints() }
    func testDiscoveryRejectsAuthorityAndPathInjection() throws { try PublicationCases.discoveryInjection() }
    func testRedirectsRequireTheSameHTTPSOrigin() throws { try PublicationCases.redirects() }
}
#endif

#if canImport(XCTest) || PUBLICATION_STANDALONE_TESTS
private enum PublicationCases {
    private struct Failure: Error, CustomStringConvertible { let description: String }
    private static func check(_ condition: Bool, _ message: String) throws {
        if !condition { throw Failure(description: message) }
    }
    private static func rejects(_ body: () throws -> Void, _ message: String) throws {
        do { try body() } catch { return }
        throw Failure(description: message)
    }
    private static let account = SignedInAccount(xuid: "24680", gamertag: "Synthetic account",
        sessionTicket: "NONSECRET_SESSION_TICKET", entityToken: "NONSECRET_ENTITY_TOKEN",
        entityId: "NONSECRET_ENTITY_ID", expiresAt: Date(timeIntervalSince1970: 2_000_000_000))
    private static func services() throws -> MCCServiceConfiguration {
        try MCCServiceConfiguration(upload: URL(string: "https://mcc-production.azurefd.net/test/upload")!,
            permission: URL(string: "https://mcc-production.azurefd.net/test/permission")!, source: "offline fixture")
    }

    static func framing() throws {
        let map = try fixture(mapID: 10050, trailer: Data(repeating: 0, count: 27))
        let original = map.bytes
        let plan = try FreshMapMetadata.makePlan(map: map, account: account)
        let request = try plan.request(credentials: account, services: services())
        let binaryLength = Int(request.headers["ContentLength"] ?? "") ?? -1
        let metadataLength = Int(request.headers["MetadataLength"] ?? "") ?? -1
        try check(binaryLength == 29_481, "ContentLength must be the native 0x7329 BLF extent")
        try check(binaryLength == map.embeddedLength, "ContentLength must exclude the physical trailer")
        try check(request.body.prefix(binaryLength) == original.prefix(binaryLength), "The upload changed embedded BLF bytes")
        try check(request.body.count == binaryLength + metadataLength, "The framed request lengths do not cover the body")
        let metadataBytes = Data(request.body.dropFirst(binaryLength))
        let parsed = try JSONDecoder().decode(JSONValue.self, from: metadataBytes)
        try check(parsed["Title"]["neutral"].string == "Café 星 🚀", "Unicode map title was not preserved")
        try check(parsed["Description"]["neutral"].string == "Synthetic description — no personal metadata.", "Unicode description was not preserved")
        guard let text = String(data: metadataBytes, encoding: .utf8) else { throw Failure(description: "Metadata is not UTF-8") }
        try check(metadataLength == text.utf8.count, "MetadataLength must count UTF-8 bytes")
        try check(metadataLength > text.count, "The fixture must distinguish characters from transmitted bytes")
        try check(parsed["DisplayProperties"]["FileSize"].string == "29481", "Catalog FileSize must match transmitted BLF bytes")
        try check(parsed["ContentType"].string == "MapVariant", "The native map-variant content type is missing")
        try check(map.bytes == original && map.trailingByteCount == 27, "Preparing the request changed the source file")
        try check(request.headers["FileAdditionalMetadata"] == nil, "A fresh map must not manufacture inherited signature metadata")
        try check(parsed["SecureData"] == .null && parsed["SecureDataSignature"] == .null, "A fresh map must not invent signed provenance")
    }

    static func credentials() throws {
        let map = try fixture(mapID: 3006)
        let plan = try FreshMapMetadata.makePlan(map: map, account: account)
        let request = try plan.request(credentials: account, services: services())
        try check(request.headers["EntityToken"] == account.entityToken, "EntityToken must carry the PlayFab entity credential")
        try check(request.headers["x-auth-token"] == account.sessionTicket, "x-auth-token must carry the PlayFab SessionTicket")
        try check(request.headers["EntityToken"] != request.headers["x-auth-token"], "SessionTicket and EntityToken must remain distinct")
        try check(request.headers["AuthorFileXuid"] == "24680" && request.headers["Sandbox"] == "RETAIL", "Publishing identity headers are incorrect")
        try check(plan.metadata["DisplayProperties"]["CreatorId"].string == account.xuid,
                  "A fresh catalog CreatorId must identify the authenticated owner independently of source authorship")
        guard let fileID = request.headers["FileName"], let guid = UUID(uuidString: fileID) else {
            throw Failure(description: "The upload filename must be a UUID")
        }
        try check(fileID == guid.uuidString.lowercased(), "The upload filename must use lowercase hyphens without an extension")
        try check(plan.metadata["DisplayProperties"]["FileName"].string == fileID, "The filename header and catalog metadata must match")
        try check(map.fileName == "fixture.mvar", "The local source filename changed")
        let other = SignedInAccount(xuid: "13579", gamertag: "Another synthetic account",
            sessionTicket: "NONSECRET_OTHER_TICKET", entityToken: "NONSECRET_OTHER_ENTITY", entityId: "other", expiresAt: account.expiresAt)
        try rejects({ _ = try plan.request(credentials: other, services: services()) }, "An upload prepared for another account was accepted")
    }

    static func catalog() throws {
        for (scenario, catalogID, tag) in [(UInt32(10050), "208", "_map_id_haloreach_breakneck"),
                                           (UInt32(3006), "209", "_map_id_haloreach_forge_world")] {
            let plan = try FreshMapMetadata.makePlan(map: fixture(mapID: scenario), account: account)
            try check(plan.metadata["DisplayProperties"]["BuiltInMapId"].string == catalogID,
                      "A raw Reach scenario ID was used as the MCC catalog enum")
            let tags = plan.metadata["Tags"].array?.compactMap(\.string) ?? []
            try check(tags == ["HaloReach", tag, "PC"], "The base-map catalog tags differ from the native mapinfo fixture")
            try check(plan.metadata["DisplayProperties"]["GameEngine"].string == "6", "Halo Reach uses MCC game-engine enum 6")
            try check(plan.metadata["Platforms"].array == [.string("2")], "The PC platform catalog field is incorrect")
        }
    }

    static func unknownMap() throws {
        let map = try fixture(mapID: 500)
        try rejects({ _ = try FreshMapMetadata.makePlan(map: map, account: account) }, "An unknown base scenario must block publication")
    }

    static func provenance() throws {
        // Synthetic _fsm framing and an unknown nonzero byte are both unsupported
        // provenance, rather than padding that can be excluded from a fresh upload.
        let fsm = Data([0x5f, 0x66, 0x73, 0x6d, 0, 0, 0, 16, 0, 1, 0, 1, 0, 0, 0, 0])
        for trailer in [Data([1]), fsm] {
            let map = try fixture(mapID: 10050, trailer: trailer)
            let original = map.bytes
            try rejects({ _ = try FreshMapMetadata.makePlan(map: map, account: account) },
                        "Unsupported provenance was silently removed from a fresh upload")
            try check(map.bytes == original, "Rejecting provenance changed the source bytes")
        }
    }

    static func discovery() throws {
        let root = discoveryFixture(host: "mcc-production.azurefd.net", path: "/test/upload")
        let direct = try MCCServiceConfiguration.discovered(from: root, source: "offline fixture")
        let wrapped = try MCCServiceConfiguration.discovered(from: .object(["data": root]), source: "offline fixture")
        try check(direct == wrapped, "Discovery must accept the native payload and its data envelope")
        try check(direct.upload.absoluteString == "https://mcc-production.azurefd.net/test/upload", "Discovery joined the wrong authority or path")
        try check(direct.permission.absoluteString == "https://mcc-production.azurefd.net/test/permission", "Discovery omitted the permission route")
        try check(direct.sandbox == "RETAIL", "Discovery selected a non-retail sandbox")
    }

    static func authorityTransport() throws {
        for (scheme, port): (Int?, Int?) in [(1, 443), (2, 80), (2, 4443), (nil, 443), (2, nil)] {
            try rejects({ _ = try MCCServiceConfiguration.discovered(
                from: discoveryFixture(host: "mcc-production.azurefd.net", path: "/test/upload", scheme: scheme, port: port),
                source: "invalid authority fixture") }, "Discovery silently overrode an unsupported authority transport")
        }
    }

    static func endpoints() throws {
        for url in [
            "http://mcc-production.azurefd.net/test/upload",
            "https://mcc-production.azurefd.net.attacker.example/test/upload",
            "https://attacker.example/test/upload",
            "https://svc.halowaypoint.com.attacker.example/test/upload",
            "https://user:password@mcc-production.azurefd.net/test/upload",
            "https://mcc-production.azurefd.net:4443/test/upload",
            "https://mcc-production.azurefd.net/test/upload?redirect=https://attacker.example",
            "https://mcc-production.azurefd.net/test/upload#fragment",
        ] {
            try rejects({ _ = try MCCServiceConfiguration(upload: URL(string: url)!,
                permission: services().permission, source: "malicious fixture") }, "A malicious endpoint configuration was accepted")
        }
        try MCCServiceConfiguration.validate(URL(string: "https://gamecms-hacs.svc.halowaypoint.com/test")!)
        try MCCServiceConfiguration.validate(URL(string: "https://mcc-production.azurefd.net:443/test")!)
    }

    static func discoveryInjection() throws {
        for (host, path) in [
            ("mcc-production.azurefd.net@attacker.example", "/test/upload"),
            ("mcc-production.azurefd.net.attacker.example", "/test/upload"),
            ("mcc-production.azurefd.net", "//attacker.example/test/upload"),
            ("https://attacker.example", "/test/upload"),
            ("mcc-production.azurefd.net", "/test/upload?redirect=attacker.example"),
        ] {
            try rejects({ _ = try MCCServiceConfiguration.discovered(from: discoveryFixture(host: host, path: path),
                source: "malicious discovery fixture") }, "Discovery authority/path injection was accepted")
        }
        try rejects({ _ = try MCCServiceConfiguration.discovered(from: .object([:]), source: "missing") }, "Missing discovery endpoints were accepted")
    }

    static func redirects() throws {
        let original = URL(string: "https://mcc-production.azurefd.net/test/upload")!
        try check(HTTPClient.permitsRedirect(from: original, to: URL(string: "https://mcc-production.azurefd.net:443/test/next")!), "An equivalent HTTPS origin should remain allowed")
        for candidate in [
            "https://attacker.example/test/upload",
            "http://mcc-production.azurefd.net/test/upload",
            "https://mcc-production.azurefd.net:4443/test/upload",
            "https://user:password@mcc-production.azurefd.net/test/upload",
            "https://mcc-production.azurefd.net.attacker.example/test/upload",
        ] {
            try check(!HTTPClient.permitsRedirect(from: original, to: URL(string: candidate)!), "A redirect changed the authenticated request origin")
        }
    }

    private static func discoveryFixture(host: String, path: String, scheme: Int? = 2, port: Int? = 443) -> JSONValue {
        .object([
            "Authorities": .object(["mcc-api": .object([
                "Hostname": .string(host),
                "Scheme": scheme.map { .number(Double($0)) } ?? .null,
                "Port": port.map { .number(Double($0)) } ?? .null,
            ])]),
            "Endpoints": .object([
                "MCCAzureFunctions_UploadFile": .object(["AuthorityId": .string("mcc-api"), "Path": .string(path)]),
                "MCCAzureFunctions_GetUploadPermission": .object(["AuthorityId": .string("mcc-api"), "Path": .string("/test/permission")]),
            ]),
        ])
    }

    // Protocol-shaped fixture: native envelope extent, plain LE-length SHA1 and
    // MSB-first Reach body. It contains no real account, map or provenance data.
    private static func fixture(mapID: UInt32, trailer: Data = Data()) throws -> ReachMapDocument {
        func chunk(_ magic: String, _ size: Int, _ major: UInt8, _ minor: UInt8) -> Data {
            var result = Data(repeating: 0, count: size)
            result.replaceSubrange(0 ..< 4, with: magic.utf8)
            for index in 0 ..< 4 { result[4 + index] = UInt8(truncatingIfNeeded: size >> ((3 - index) * 8)) }
            result[9] = major; result[11] = minor
            return result
        }
        func little(_ data: inout Data, _ offset: Int, _ value: UInt64, _ count: Int) {
            for index in 0 ..< count { data[offset + index] = UInt8(truncatingIfNeeded: value >> (index * 8)) }
        }
        var start = chunk("_blf", 48, 1, 2); start[12] = 0xff; start[13] = 0xfe
        var header = chunk("chdr", 704, 10, 2); header[0x10] = 5
        little(&header, 0x14, 0x7329, 4); little(&header, 0x3c, UInt64(mapID), 4)
        for (offset, text) in [(0x90, "Café 星 🚀"), (0x190, "Synthetic description — no personal metadata.")] {
            let bytes = text.data(using: .utf16LittleEndian)!
            header.replaceSubrange(offset ..< offset + bytes.count, with: bytes)
        }
        var bits = Writer(); bits.add(6, 4); bits.add(0x7329, 32); bits.zeros(64 * 4 + 9)
        bits.add(UInt64(mapID), 32); bits.zeros(8)
        for _ in 0 ..< 2 { bits.zeros(128 + 8 + 1) }
        bits.zeros(32); bits.add(32, 8); bits.zeros(64 + 9); bits.add(UInt64(mapID), 32); bits.zeros(2)
        for value: Float in [-100, 100, -100, 100, -100, 100] { bits.add(UInt64(value.bitPattern), 32) }
        bits.zeros(64 + 9 + 128 + 651)
        let payload = Data(bits.bytes); var variant = chunk("mvar", 0x7028, 31, 1)
        var hashInput = Data((0 ..< 4).map { UInt8(truncatingIfNeeded: payload.count >> ($0 * 8)) })
        hashInput.append(payload)
        variant.replaceSubrange(12 ..< 32, with: Array(Insecure.SHA1.hash(data: hashInput)))
        for index in 0 ..< 4 { variant[32 + index] = UInt8(truncatingIfNeeded: payload.count >> ((3 - index) * 8)) }
        variant.replaceSubrange(36 ..< 36 + payload.count, with: payload)
        var eof = chunk("_eof", 17, 1, 1)
        for index in 0 ..< 4 { eof[12 + index] = UInt8(truncatingIfNeeded: 0x7318 >> ((3 - index) * 8)) }
        return try ReachMapDocument(data: start + header + variant + eof + trailer, fileName: "fixture.mvar")
    }
    private struct Writer {
        var bytes: [UInt8] = []; var length = 0
        mutating func zeros(_ count: Int) { for _ in 0 ..< count { add(0, 1) } }
        mutating func add(_ value: UInt64, _ count: Int) {
            for shift in stride(from: count - 1, through: 0, by: -1) {
                if length % 8 == 0 { bytes.append(0) }
                bytes[length / 8] |= UInt8((value >> shift) & 1) << (7 - length % 8)
                length += 1
            }
        }
    }
}

#if PUBLICATION_STANDALONE_TESTS
@main
struct PublicationStandaloneTests {
    static func main() throws {
        try PublicationCases.framing()
        try PublicationCases.credentials()
        try PublicationCases.catalog()
        try PublicationCases.unknownMap()
        try PublicationCases.provenance()
        try PublicationCases.discovery()
        try PublicationCases.authorityTransport()
        try PublicationCases.endpoints()
        try PublicationCases.discoveryInjection()
        try PublicationCases.redirects()
        print("Publication tests: 10 cases passed; native binary/UTF-8 framing, credentials, map catalog, provenance, authority transport, endpoint and redirect checks; no network.")
    }
}
#endif
#endif
