import Foundation
import CryptoKit
import CZlib

#if canImport(XCTest) && !FILESHARE_STANDALONE_TESTS
import XCTest
@testable import MCCPublisherCore

final class FileShareTests: XCTestCase {
    func testOwnedMixedGameListingAndRequest() async throws { try await FileShareCases.listing() }
    func testCompletenessAndMalformedEntriesRemainVisible() async throws { try await FileShareCases.completeness() }
    func testContinuationNeverPretendsToBeComplete() async throws { try await FileShareCases.continuation() }
    func testErrorEnvelopesCannotLookEmpty() async throws { try await FileShareCases.envelopes() }
    func testDetailsAndDownloadAreBoundToAccountAndID() async throws { try await FileShareCases.binding() }
    func testDownloadSelectsMapDataAndPreservesAllBytes() async throws { try await FileShareCases.download() }
    func testGametypeDownloadRetainsKindAndBytes() async throws { try await FileShareCases.gametypeDownload() }
    func testLegacyXboxContentMayBeUntyped() async throws { try await FileShareCases.legacyDownload() }
    func testExpiredCDNURLRefreshesDetailsOnce() async throws { try await FileShareCases.expiredURL() }
    func testMissingAmbiguousAndUnsafeDownloadURLs() async throws { try await FileShareCases.badContents() }
    func testInvalidAndTruncatedPayloadsAreRejected() async throws { try await FileShareCases.badPayloads() }
    func testMultipleTitlesAndCompressedBLF() throws { try FileShareCases.formats() }
    func testAtomicSaveAndFailedSaveCleanup() throws { try FileShareCases.save() }
    func testCancellationLeavesExistingDestination() async throws { try await FileShareCases.cancelledSave() }
    func testReadableSafeUniqueDefaultFilename() async throws { try await FileShareCases.filenames() }
    func testSavedConfigurationCompatibilityAndReadRoutes() throws { try FileShareCases.configuration() }
    func testScopedURLIsAbsentFromNetworkErrors() async throws { try await FileShareCases.networkError() }
}
#endif

#if canImport(XCTest) || FILESHARE_STANDALONE_TESTS
private final class FileShareURLProtocol: URLProtocol, @unchecked Sendable {
    struct Reply { var data: Data; var status = 200; var headers: [String: String] = [:] }
    static var handle: ((URLRequest) throws -> Reply)?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            guard let handler = Self.handle else { throw URLError(.badServerResponse) }
            let reply = try handler(request)
            let response = HTTPURLResponse(url: request.url!, statusCode: reply.status, httpVersion: "HTTP/1.1", headerFields: reply.headers)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: reply.data)
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}

private enum FileShareCases {
    struct Failure: Error, CustomStringConvertible { let description: String }
    static func check(_ condition: Bool, _ message: String) throws { if !condition { throw Failure(description: message) } }
    static func rejects(_ message: String, _ work: () throws -> Void) throws {
        do { try work() } catch { return }; throw Failure(description: message)
    }
    static func rejectsAsync(_ message: String, _ work: () async throws -> Void) async throws {
        do { try await work() } catch { return }; throw Failure(description: message)
    }
    static let firstID = "00000000-0000-0000-0000-000000000001"
    static let secondID = "00000000-0000-0000-0000-000000000002"
    static let thirdID = "00000000-0000-0000-0000-000000000003"
    static let account = SignedInAccount(xuid: "123456", gamertag: "Synthetic", sessionTicket: "FAKE_SESSION", entityToken: "FAKE_ENTITY_TOKEN", entityId: "FAKE_OWNER", expiresAt: .distantFuture)
    static let other = SignedInAccount(xuid: "999999", gamertag: "Other", sessionTicket: "OTHER_SESSION", entityToken: "OTHER_TOKEN", entityId: "OTHER_OWNER", expiresAt: .distantFuture)
    static func services() throws -> MCCServiceConfiguration {
        try MCCServiceConfiguration(upload: URL(string: "https://mcc-production.azurefd.net/test/upload")!, permission: URL(string: "https://mcc-production.azurefd.net/test/permission")!,
            itemLookup: URL(string: "https://mcc-production.azurefd.net/test/detail")!, itemListing: URL(string: "https://mcc-production.azurefd.net/test/list")!, source: "offline fixture")
    }
    static func service(_ handler: @escaping (URLRequest) throws -> FileShareURLProtocol.Reply) -> FileShareService {
        FileShareURLProtocol.handle = handler
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [FileShareURLProtocol.self]
        return FileShareService(http: HTTPClient(session: URLSession(configuration: config)))
    }
    static func reply(_ json: JSONValue) throws -> FileShareURLProtocol.Reply { .init(data: try json.encoded(), headers: ["Content-Type": "application/json"]) }
    static func row(id: String = firstID, type: String = "MapVariant", owner: String = account.entityId, engine: String = "6", title: String = "Same map title", contents: [JSONValue]? = nil) -> JSONValue {
        var value: [String: JSONValue] = [
            "Id": .string(id), "ContentType": .string(type), "CreatorEntity": .object(["Id": .string(owner), "Type": .string("title_player_account")]),
            "Title": .object(["NEUTRAL": .string(title)]), "Description": .object(["neutral": .string("Fixture description")]),
            "DisplayProperties": .object(["GameEngine": .string(engine), "BuiltInMapId": .string("209"), "FileName": .string(UUID().uuidString), "FileSize": .string("29481")]),
            "LastModifiedDate": .string("2026-10-18T12:00:00.123Z"),
        ]
        if let contents { value["Contents"] = .array(contents) }
        return .object(value)
    }
    static func listBody(_ rows: [JSONValue], count: JSONValue? = nil) -> JSONValue {
        .object(["Count": count ?? .number(Double(rows.count)), "Items": .array(rows)])
    }
    static func dataContent(_ url: String = "https://content1.prod.catalog.playfab.com/map?sig=NONSECRET") -> JSONValue {
        .object(["Type": .string("data"), "Url": .string(url), "Id": .string("fake-content")])
    }
    static func selectedItem() async throws -> FileShareItem {
        let client = service { _ in try reply(listBody([row()])) }
        return try await client.list(credentials: account, services: services()).items[0]
    }

    static func listing() async throws {
        let rows = [row(engine: "2"), row(id: secondID, engine: "3"), row(id: thirdID, type: "GameVariant")]
        var requests: [URLRequest] = []
        for wrapped in [false, true] {
            let client = service { request in
                requests.append(request)
                let body = listBody(rows)
                return try reply(wrapped ? .object(["code": .number(200), "data": body]) : body)
            }
            let result = try await client.list(credentials: account, services: services())
            try check(result.isComplete && result.warning == nil && result.catalogItemCount == 3, "Valid response was not complete")
            try check(result.items.count == 3 && result.items[0].title == result.items[1].title && result.items[0].id != result.items[1].id, "Duplicate titles lost stable identity")
            try check(result.items.map(\.game) == ["Halo 3", "Halo 4", "Halo: Reach"] && result.items[2].kind == .gametype, "MCC API game mapping or gametype classification is wrong")
            try check(result.items[0].description == "Fixture description" && result.items[0].fileSize == 29481 && result.items[0].modifiedAt != nil, "Optional metadata was lost")
        }
        for request in requests {
            try check(request.httpMethod == "POST" && request.url?.path == "/test/list", "Browsing invoked an unrelated endpoint or remote mutation")
            try check(request.value(forHTTPHeaderField: "CreatorEntityId") == account.entityId && request.value(forHTTPHeaderField: "UserEntityId") == account.entityId, "Own-account listing headers were missing")
        }
    }

    static func gametypeDownload() async throws {
        let source = service { _ in try reply(listBody([row(type: "GameVariant", title: "Arena Slayer")])) }
        let item = try await source.list(credentials: account, services: services()).items[0]
        var bytes = fixture(version: 137, fsm: true)
        bytes.replaceSubrange(48 + 704..<48 + 704 + 4, with: "mpvr".utf8)
        let client = service { request in
            if request.url?.path == "/test/detail" { return try reply(.object(["Item": row(type: "GameVariant", contents: [dataContent()])])) }
            return .init(data: bytes, headers: ["Content-Type": "application/octet-stream"])
        }
        let result = try await client.download(item: item, credentials: account, services: services())
        try check(result.kind == .gametype && result.data == bytes && item.suggestedFilename.hasSuffix(".bin"), "Gametype catalog kind, game-independent version, or full bytes were lost")
        let wrongType = service { _ in try reply(.object(["Item": row(type: "MapVariant", contents: [dataContent()])])) }
        try await rejectsAsync("Catalog type changed after selection without rejection") { _ = try await wrongType.download(item: item, credentials: account, services: services()) }
    }

    static func completeness() async throws {
        var invalid = row().object!; invalid["Id"] = .string("invalid-id")
        var missingType = row().object!; missingType.removeValue(forKey: "ContentType")
        let missingOwner = row(owner: "")
        let responses: [JSONValue] = [listBody([row()], count: .number(2)), listBody([], count: .null), listBody([], count: .number(0.5)), listBody([row(), .object(invalid)]), listBody([row(), .object(missingType)]), listBody([row(), missingOwner]), listBody([row(), row()])]
        for response in responses {
            let client = service { _ in try reply(response) }
            let listing = try await client.list(credentials: account, services: services())
            try check(!listing.isComplete && listing.warning != nil, "Malformed/partial response was silently represented as complete")
            try check(listing.items.count <= 1, "Malformed entries were shown as owned maps")
        }
        let client = service { _ in try reply(listBody([])) }
        let empty = try await client.list(credentials: account, services: services())
        try check(empty.isComplete && empty.items.isEmpty, "A verified empty share was not recognized")
    }

    static func continuation() async throws {
        for (key, value): (String, JSONValue) in [("ContinuationToken", .string("opaque-token")), ("HasMore", .bool(true)), ("nextLink", .string("https://attacker.example"))] {
            var body = listBody([row()]).object!; body[key] = value
            var calls = 0
            let client = service { _ in calls += 1; return try reply(.object(body)) }
            let result = try await client.list(credentials: account, services: services())
            try check(!result.isComplete && result.items.count == 1 && calls == 1, "Unsupported paging was hidden or an invented endpoint was followed")
            let wrapped = service { _ in try reply(.object([key: value, "data": listBody([row()])])) }
            let wrappedResult = try await wrapped.list(credentials: account, services: services())
            try check(!wrappedResult.isComplete, "Continuation on the outer envelope was hidden")
        }
    }

    static func envelopes() async throws {
        for body: JSONValue in [.null, .array([]), .object([:]), .object(["Items": .string("bad"), "Count": .number(0)]), .object(["Error": .object([:]), "Items": .array([]), "Count": .number(0)]), .object(["code": .number(500), "data": listBody([])])] {
            let client = service { _ in try reply(body) }
            try await rejectsAsync("An error/malformed envelope was accepted as an empty list") { _ = try await client.list(credentials: account, services: services()) }
        }
        for body: JSONValue in [.object(["code": .string("error"), "data": listBody([])]), .object(["data": .array([]), "Items": .array([]), "Count": .number(0)])] {
            let client = service { _ in try reply(body) }
            try await rejectsAsync("Malformed wrapper fields produced a complete empty list") { _ = try await client.list(credentials: account, services: services()) }
        }
    }

    static func binding() async throws {
        let item = try await selectedItem()
        var calls = 0
        let client = service { _ in calls += 1; return try reply(.object(["Item": row()])) }
        try await rejectsAsync("Cross-account selection downloaded") { _ = try await client.download(item: item, credentials: other, services: services()) }
        let expired = SignedInAccount(xuid: account.xuid, gamertag: account.gamertag, sessionTicket: "", entityToken: account.entityToken, entityId: account.entityId, expiresAt: .distantPast)
        try await rejectsAsync("Expired account was sent to service") { _ = try await client.list(credentials: expired, services: services()) }
        try check(calls == 0, "Invalid account state made a network request")
        for raw in [row(id: secondID), row(owner: other.entityId), row(type: "GameVariant")] {
            let client = service { _ in try reply(.object(["data": .object(["Item": raw])])) }
            try await rejectsAsync("Detail identity or owner mismatch was accepted") { _ = try await client.download(item: item, credentials: account, services: services()) }
        }
    }

    static func download() async throws {
        let item = try await selectedItem()
        let bytes = fixture(version: 50, fsm: true)
        var calls: [URLRequest] = []
        let client = service { request in
            calls.append(request)
            if request.url?.path == "/test/detail" {
                return try reply(.object(["data": .object(["Item": row(engine: "3", contents: [.object(["Type": .string("thumbnail"), "Url": .string("https://content1.prod.catalog.playfab.com/thumbnail")]), dataContent()])])]))
            }
            return .init(data: bytes, headers: ["Content-Type": "application/octet-stream"])
        }
        let result = try await client.download(item: item, credentials: account, services: services())
        try check(result.data == bytes && result.sha256 == SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined(), "Download changed BLF/provenance bytes or hash")
        try check(calls.count == 2 && calls[0].httpMethod == "POST" && calls[1].httpMethod == "GET" && calls[1].url?.path == "/map", "Data selection used thumbnail or performed a remote mutation")
        try check(calls[0].value(forHTTPHeaderField: "X-EntityToken") == account.entityToken, "Lookup lacked entity authentication")
        for key in ["X-EntityToken", "EntityToken", "x-auth-token", "Authorization", "CreatorEntityId", "UserEntityId"] { try check(calls[1].value(forHTTPHeaderField: key) == nil, "CDN received an account credential") }
    }

    static func expiredURL() async throws {
        let item = try await selectedItem(); var details = 0; var cdn = 0
        let client = service { request in
            if request.url?.path == "/test/detail" {
                details += 1
                return try reply(.object(["Item": row(contents: [dataContent("https://content1.prod.catalog.playfab.com/map?version=\(details)")])]))
            }
            cdn += 1
            return cdn == 1 ? .init(data: Data(), status: 403) : .init(data: fixture(version: 31))
        }
        _ = try await client.download(item: item, credentials: account, services: services())
        try check(details == 2 && cdn == 2, "An expired scoped URL was retried without fresh details")
    }

    static func legacyDownload() async throws {
        let item = try await selectedItem()
        let bytes = fixture(version: 12, fsm: true, hasHeader: false)
        let legacy: JSONValue = .object(["Id": .string("legacy-content"), "Tags": .array([]), "Url": .string("https://xforgeassets002.xboxlive.com/ugc/map")])
        let thumbnail: JSONValue = .object(["Type": .string("thumbnail"), "Url": .string("https://xforgeassets002.xboxlive.com/ugc/thumb")])
        for contents in [[legacy], [thumbnail, legacy], [dataContent("https://xforgeassets002.xboxlive.com/ugc/map")]] {
            var requests: [URLRequest] = []
            let client = service { request in
                requests.append(request)
                return request.url?.path == "/test/detail" ? try reply(.object(["Item": row(contents: contents)])) : .init(data: bytes)
            }
            let result = try await client.download(item: item, credentials: account, services: services())
            try check(result.data == bytes && requests.count == 2 && requests[1].url?.path == "/ugc/map", "Observed legacy Xbox content was rejected or a thumbnail selected")
            try check(requests[1].value(forHTTPHeaderField: "X-EntityToken") == nil, "Legacy CDN received account credentials")
        }
        for contents in [[legacy, legacy], [thumbnail], [.object(["Type": .string("image"), "Url": .string("https://xforgeassets002.xboxlive.com/ugc/image")])]] {
            let client = service { _ in try reply(.object(["Item": row(contents: contents)])) }
            try await rejectsAsync("Ambiguous untyped contents or explicit image was saved as a map") { _ = try await client.download(item: item, credentials: account, services: services()) }
        }
        try check(!FileShareService.trustedDownloadURL(URL(string: "https://xforgeassets002.xboxlive.com.attacker.example/map")!), "Legacy CDN suffix confusion was accepted")
    }

    static func badContents() async throws {
        let item = try await selectedItem()
        let invalidSets = [[], [.object(["Type": .string("thumbnail"), "Url": .string("https://content1.prod.catalog.playfab.com/thumb")])], [dataContent(), dataContent()]]
        for contents in invalidSets {
            let client = service { _ in try reply(.object(["Item": row(contents: contents)])) }
            try await rejectsAsync("Missing/ambiguous data content was accepted") { _ = try await client.download(item: item, credentials: account, services: services()) }
        }
        for address in ["http://content1.prod.catalog.playfab.com/map", "https://content1.prod.catalog.playfab.com.attacker.example/map", "https://u:p@content1.prod.catalog.playfab.com/map", "https://content1.prod.catalog.playfab.com:8443/map", "https://attacker.example/map", "https://content1.prod.catalog.playfab.com/map#fragment"] {
            var calls = 0
            let client = service { _ in calls += 1; return try reply(.object(["Item": row(contents: [dataContent(address)])])) }
            try await rejectsAsync("An unsafe download host was contacted") { _ = try await client.download(item: item, credentials: account, services: services()) }
            try check(calls == 1, "Unsafe content URL received a request")
        }
    }

    static func badPayloads() async throws {
        let item = try await selectedItem()
        for bytes in [Data(), Data("{\"error\":\"expired\"}".utf8), Data("<!doctype html>error".utf8), fixture(version: 31).dropLast(), fixture(version: 31).prefix(50)] {
            let client = service { request in request.url?.path == "/test/detail" ? try reply(.object(["Item": row(contents: [dataContent()])])) : .init(data: Data(bytes)) }
            try await rejectsAsync("Invalid/truncated map payload was accepted") { _ = try await client.download(item: item, credentials: account, services: services()) }
        }
        let client = service { request in request.url?.path == "/test/detail" ? try reply(.object(["Item": row(contents: [dataContent()])])) : .init(data: fixture(version: 31), headers: ["Content-Type": "application/json"]) }
        try await rejectsAsync("Error-document MIME was accepted") { _ = try await client.download(item: item, credentials: account, services: services()) }
    }

    static func formats() throws {
        for version in [12, 31, 50, 52, 99] {
            let bytes = fixture(version: version, fsm: true, hasHeader: version != 12)
            let result = try FileShareDownload(data: bytes, itemID: firstID)
            try check(result.data == bytes, "A different-title BLF version was rejected or changed")
        }
        let opaqueTrailer = fixture(version: 31) + Data([0x01, 0x02, 0x03, 0x04, 0xde, 0xad])
        try check(try FileShareDownload(data: opaqueTrailer, itemID: firstID).data == opaqueTrailer, "Opaque physical trailer was rejected or stripped")
        let payload = chunk("mvar", 100, 31)
        var compressed = [UInt8](repeating: 0, count: Int(compressBound(uLong(payload.count))))
        var length = uLongf(compressed.count)
        let status = compressed.withUnsafeMutableBufferPointer { out in payload.withUnsafeBytes { source in compress2(out.baseAddress, &length, source.bindMemory(to: UInt8.self).baseAddress, uLong(payload.count), Z_BEST_COMPRESSION) } }
        try check(status == Z_OK, "Fixture compression failed")
        var wrapper = chunk("_cmp", 17 + Int(length), 1); wrapper[12] = 0
        putBE(&wrapper, 13, payload.count); wrapper.replaceSubrange(17..<wrapper.count, with: compressed.prefix(Int(length)))
        let bytes = chunk("_blf", 48, 1) + wrapper + chunk("_eof", 17, 1)
        try check(try FileShareDownload(data: bytes, itemID: firstID).data == bytes, "Compressed bytes were expanded in the saved file")
        var corrupt = bytes; corrupt[70] ^= 0xff
        try rejects("Corrupt compressed data was accepted") { _ = try FileShareDownload(data: corrupt, itemID: firstID) }
        try rejects("Multiple map payloads were accepted") { _ = try FileShareDownload(data: chunk("_blf", 48, 1) + payload + payload + chunk("_eof", 17, 1), itemID: firstID) }
    }

    static func save() throws {
        let manager = FileManager.default
        let dir = manager.temporaryDirectory.appendingPathComponent("mcc-fileshare-tests-\(UUID())")
        try manager.createDirectory(at: dir, withIntermediateDirectories: false)
        defer { try? manager.removeItem(at: dir) }
        let bytes = fixture(version: 12, fsm: true, hasHeader: false)
        let download = try FileShareDownload(data: bytes, itemID: firstID)
        let destination = dir.appendingPathComponent("fixture.mvar")
        try Data("existing file".utf8).write(to: destination)
        try download.save(to: destination)
        try check(try Data(contentsOf: destination) == bytes, "Saved bytes differ from fetched bytes")
        let failDestination = dir.appendingPathComponent("directory.mvar")
        try manager.createDirectory(at: failDestination, withIntermediateDirectories: false)
        try rejects("Saving onto a directory succeeded") { try download.save(to: failDestination) }
        try rejects("A nonexistent save parent succeeded") { try download.save(to: dir.appendingPathComponent("missing/map.mvar")) }
        try rejects("An incorrect extension was accepted") { try download.save(to: dir.appendingPathComponent("map.json")) }
        let remaining = try manager.contentsOfDirectory(atPath: dir.path)
        try check(remaining.sorted() == ["directory.mvar", "fixture.mvar"], "A failed save left staging or final-looking artifacts")
    }

    static func cancelledSave() async throws {
        let manager = FileManager.default
        let dir = manager.temporaryDirectory.appendingPathComponent("mcc-cancel-tests-\(UUID())")
        try manager.createDirectory(at: dir, withIntermediateDirectories: false)
        defer { try? manager.removeItem(at: dir) }
        let url = dir.appendingPathComponent("existing.mvar")
        let original = Data("existing map".utf8); try original.write(to: url)
        let download = try FileShareDownload(data: fixture(version: 31), itemID: firstID)
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            try download.save(to: url)
        }
        try await rejectsAsync("A cancelled save succeeded") { try await task.value }
        try check(try Data(contentsOf: url) == original, "Cancellation altered existing destination")
    }

    static func filenames() async throws {
        let rows = [row(title: "../A:B/星\\file\n.mvar"), row(id: secondID, title: "../A:B/星\\file\n.mvar"), row(id: thirdID, title: "... ")]
        let client = service { _ in try reply(listBody(rows)) }
        let items = try await client.list(credentials: account, services: services()).items
        for item in items {
            let name = item.suggestedFilename
            try check(name.hasSuffix(".mvar") && !name.contains("/") && !name.contains("\\") && !name.contains(":") && !name.contains("\n") && !name.hasPrefix(".") && name.utf8.count <= 255, "Default filename is not a safe readable component")
        }
        try check(items[0].suggestedFilename != items[1].suggestedFilename, "Duplicate titles have indistinguishable default filenames")
    }

    static func configuration() throws {
        let old = JSONValue.object(["upload": .string("https://mcc-production.azurefd.net/upload"), "permission": .string("https://mcc-production.azurefd.net/permission"), "itemLookup": .string("https://mcc-production.azurefd.net/lookup"), "source": .string("legacy fixture"), "sandbox": .string("RETAIL")])
        let config = try JSONDecoder().decode(MCCServiceConfiguration.self, from: old.encoded())
        try check(config.itemListing.lastPathComponent == "GetPlayFabUgcItems", "Old settings did not acquire listing default")
        try check(try JSONDecoder().decode(MCCServiceConfiguration.self, from: JSONEncoder().encode(config)) == config, "Configuration round trip lost read endpoints")
        let discovery = JSONValue.object(["Authorities": .object(["api": .object(["Scheme": .number(2), "Port": .number(443), "Hostname": .string("mcc-production.azurefd.net")])]), "Endpoints": .object(Dictionary(uniqueKeysWithValues: [("MCCAzureFunctions_UploadFile", "/upload"), ("MCCAzureFunctions_GetUploadPermission", "/permission"), ("MCCAzureFunctions_GetPlayFabUgcItem", "/custom-detail"), ("MCCAzureFunctions_GetPlayFabUgcItems", "/custom-list")].map { ($0, .object(["AuthorityId": .string("api"), "Path": .string($1)])) }))])
        let current = try MCCServiceConfiguration.discovered(from: discovery, source: "fixture")
        try check(current.itemListing.path == "/custom-list" && current.itemLookup.path == "/custom-detail", "Discovery ignored explicit read routes")
        var malicious = old.object!; malicious["itemListing"] = .string("https://attacker.example/list")
        try rejects("Decoded settings bypassed endpoint trust") { _ = try JSONDecoder().decode(MCCServiceConfiguration.self, from: JSONValue.object(malicious).encoded()) }
    }

    static func networkError() async throws {
        let item = try await selectedItem()
        let secret = "SCOPED_URL_MUST_NOT_BE_IN_ERROR"
        let client = service { request in
            if request.url?.path == "/test/detail" { return try reply(.object(["Item": row(contents: [dataContent("https://content1.prod.catalog.playfab.com/map?sig=\(secret)")])])) }
            throw URLError(.timedOut, userInfo: [NSLocalizedDescriptionKey: "Failure at \(request.url!.absoluteString)", NSURLErrorFailingURLErrorKey: request.url!])
        }
        do { _ = try await client.download(item: item, credentials: account, services: services()); throw Failure(description: "Network error did not fail") }
        catch let error as Failure { throw error }
        catch { try check(!error.localizedDescription.contains(secret) && !String(describing: error).contains(secret), "Scoped URL leaked through an error") }
    }

    static func chunk(_ magic: String, _ size: Int, _ version: Int) -> Data {
        var data = Data(repeating: 0, count: size)
        data.replaceSubrange(0..<4, with: magic.utf8); putBE(&data, 4, size)
        data[8] = UInt8(version >> 8); data[9] = UInt8(version & 255); data[11] = 1
        return data
    }
    static func putBE(_ data: inout Data, _ offset: Int, _ value: Int) {
        for i in 0..<4 { data[offset + i] = UInt8(truncatingIfNeeded: value >> ((3 - i) * 8)) }
    }
    static func fixture(version: Int, fsm: Bool = false, hasHeader: Bool = true) -> Data {
        var bytes = chunk("_blf", 48, 1)
        bytes[12] = 0xff; bytes[13] = 0xfe
        bytes += hasHeader ? chunk("chdr", 704, 10) : chunk("athr", 16, 3)
        bytes += chunk("mvar", 100, version)
        var eof = chunk("_eof", 17, 1); putBE(&eof, 12, bytes.count)
        bytes += eof
        if fsm { bytes += chunk("_fsm", 464, 1) }
        return bytes
    }
}

#if FILESHARE_STANDALONE_TESTS
@main struct FileShareStandaloneTests {
    static func main() async throws {
        try await FileShareCases.listing()
        try await FileShareCases.completeness()
        try await FileShareCases.continuation()
        try await FileShareCases.envelopes()
        try await FileShareCases.binding()
        try await FileShareCases.download()
        try await FileShareCases.gametypeDownload()
        try await FileShareCases.legacyDownload()
        try await FileShareCases.expiredURL()
        try await FileShareCases.badContents()
        try await FileShareCases.badPayloads()
        try FileShareCases.formats()
        try FileShareCases.save()
        try await FileShareCases.cancelledSave()
        try await FileShareCases.filenames()
        try FileShareCases.configuration()
        try await FileShareCases.networkError()
        print("File Share tests: 17 cases passed; mocked owned listing, gametypes, completeness, continuation, identities, mixed games, trusted/legacy content, URL expiry, BLF/compression, exact bytes, atomic save, cancellation, safe filenames and settings; no live network or remote writes.")
    }
}
#endif
#endif
