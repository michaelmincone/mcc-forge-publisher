import Foundation

#if canImport(XCTest) && !FILESHARE_DELETION_STANDALONE_TESTS
import XCTest
@testable import MCCPublisherCore
final class FileShareDeletionTests: XCTestCase {
    func testNativeDeleteContractAndVerifiedAbsence() async throws { try await DeletionCases.contract() }
    func testSelectionAndSessionScopeBeforeAnyRequest() async throws { try await DeletionCases.scope() }
    func testFreshOwnedMapLookupBeforeMutation() async throws { try await DeletionCases.preflightMismatch() }
    func testAlreadyAbsentRequiresCompletePreflightList() async throws { try await DeletionCases.alreadyAbsent() }
    func testUnverifiedPreflightNeverDispatchesMutation() async throws { try await DeletionCases.unverifiedPreflight() }
    func testHTTPAcknowledgementAloneIsUncertain() async throws { try await DeletionCases.staleAcknowledgement() }
    func testExplicitRefusalIsNotDeleted() async throws { try await DeletionCases.refused() }
    func testReadOnlyAbsenceOverridesRefusalAndLostReply() async throws { try await DeletionCases.reconciledAbsence() }
    func testAllCatalogTypesAreInspectedForSameID() async throws { try await DeletionCases.allTypes() }
    func testExactProviderItemNotFoundAfterDispatch() async throws { try await DeletionCases.exactNotFound() }
    func testIncompleteOrMalformedListNeverProvesAbsence() async throws { try await DeletionCases.incompleteList() }
    func testAmbiguousMutationIsNeverRetriedAndSanitizesErrors() async throws { try await DeletionCases.lostReply() }
    func testCancellationBeforeAndAfterDispatch() async throws { try await DeletionCases.cancellation() }
    func testReadOnlyReconciliationCanConfirmLaterAbsence() async throws { try await DeletionCases.reconcile() }
    func testSettingsMigrationAndNativeDeleteRoute() async throws { try await DeletionCases.configuration() }
    func testGametypeDeletionAndKindMismatch() async throws { try await DeletionCases.gametypes() }
}
#endif

#if canImport(XCTest) || FILESHARE_DELETION_STANDALONE_TESTS
private final class DeletionProtocol: URLProtocol, @unchecked Sendable {
    struct Reply { var data = Data(); var status = 200; var headers: [String: String] = [:] }
    static var handler: ((URLRequest) throws -> Reply)?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            guard let handler = Self.handler else { throw URLError(.badServerResponse) }
            let reply = try handler(request)
            let response = HTTPURLResponse(url: request.url!, statusCode: reply.status, httpVersion: "HTTP/1.1", headerFields: reply.headers)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: reply.data)
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}

private enum DeletionCases {
    struct Failure: Error, CustomStringConvertible { let description: String }
    static func check(_ condition: Bool, _ message: String) throws { if !condition { throw Failure(description: message) } }
    static func rejects(_ work: () async throws -> Void, _ message: String) async throws {
        do { try await work() } catch { return }; throw Failure(description: message)
    }
    static let itemID = "00000000-0000-0000-0000-000000000001"
    static let otherID = "00000000-0000-0000-0000-000000000002"
    static let account = SignedInAccount(xuid: "SYNTHETIC_XUID", gamertag: "Synthetic", sessionTicket: "FAKE_SESSION_TICKET", entityToken: "FAKE_ENTITY_TOKEN", entityId: "SYNTHETIC_ENTITY", expiresAt: .distantFuture)
    static func item(id: String = itemID, xuid: String = account.xuid, entity: String = account.entityId, kind: VariantKind = .map) -> FileShareItem {
        FileShareItem(id: id, title: "Synthetic selected map", description: "", game: "Halo 3", baseMap: nil, fileSize: nil, modifiedAt: nil,
            accountEntityID: entity, accountXUID: xuid, gameEngine: "2", baseMapID: nil, kind: kind)
    }
    static func config() throws -> MCCServiceConfiguration {
        try MCCServiceConfiguration(upload: URL(string: "https://mcc-production.azurefd.net/test/upload")!, permission: URL(string: "https://mcc-production.azurefd.net/test/permission")!,
            itemLookup: URL(string: "https://mcc-production.azurefd.net/test/detail")!, itemListing: URL(string: "https://mcc-production.azurefd.net/test/list")!,
            itemDeletion: URL(string: "https://mcc-production.azurefd.net/test/delete")!, source: "offline deletion fixture")
    }
    static func service(_ handler: @escaping (URLRequest) throws -> DeletionProtocol.Reply) -> FileShareDeletionService {
        DeletionProtocol.handler = handler
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [DeletionProtocol.self]
        return FileShareDeletionService(http: HTTPClient(session: URLSession(configuration: config)))
    }
    static func json(_ value: JSONValue, status: Int = 200) throws -> DeletionProtocol.Reply {
        .init(data: try value.encoded(), status: status, headers: ["Content-Type": "application/json"])
    }
    static func row(id: String = itemID, owner: String = account.entityId, type: String = "MapVariant") -> JSONValue {
        .object(["Id": .string(id), "Title": .object(["NEUTRAL": .string("Fresh remote title")]), "ContentType": .string(type),
            "CreatorEntity": .object(["Id": .string(owner)]), "DisplayProperties": .object(["GameEngine": .string("2")])])
    }
    static func details(_ row: JSONValue = row()) -> JSONValue { .object(["code": .number(200), "data": .object(["Item": row])]) }
    static func listing(_ rows: [JSONValue] = [], count: JSONValue? = nil, extra: [String: JSONValue] = [:]) -> JSONValue {
        var body: [String: JSONValue] = ["Count": count ?? .number(Double(rows.count)), "Items": .array(rows)]
        for (key, value) in extra { body[key] = value }
        return .object(["data": .object(body)])
    }
    static func requestBody(_ request: URLRequest) throws -> Data {
        if let data = request.httpBody { return data }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open(); defer { stream.close() }
        var result = Data(), buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count < 0 { throw Failure(description: "Unable to read mock request body") }
            if count == 0 { break }
            result.append(contentsOf: buffer.prefix(count))
        }
        return result
    }

    static func contract() async throws {
        var requests: [URLRequest] = []
        var deletionBody = Data()
        let client = service { request in
            requests.append(request)
            switch request.url?.path {
            case "/test/detail": return try json(details())
            case "/test/delete": deletionBody = try requestBody(request); return .init()
            case "/test/list": return try json(listing())
            default: throw Failure(description: "Deletion used an unapproved endpoint")
            }
        }
        let result = try await client.delete(item: item(), credentials: account, services: config())
        try check(result.outcome == .deleted && result.confirmedAbsent && result.itemID == itemID && result.accountXUID == account.xuid && result.accountEntityID == account.entityId && result.title == "Fresh remote title", "Confirmed result lost identity/account binding")
        try check(requests.map { $0.url!.path } == ["/test/detail", "/test/delete", "/test/list"], "Deletion did not verify ownership and reconcile through read-only listing")
        try check(requests.allSatisfy { $0.httpMethod == "POST" }, "Native methods changed")
        let mutation = requests[1]
        try check(mutation.value(forHTTPHeaderField: "X-EntityToken") == account.entityToken && mutation.value(forHTTPHeaderField: "Accept") == "application/json" && mutation.value(forHTTPHeaderField: "Content-Type") == "application/json", "Native delete credentials or content headers changed")
        try check(mutation.value(forHTTPHeaderField: "x-auth-token") == nil && mutation.value(forHTTPHeaderField: "Authorization") == nil, "Speculative credentials were added")
        try check(try JSONDecoder().decode(JSONValue.self, from: deletionBody) == .object(["ItemId": .string(itemID)]), "Delete body differs from native ItemId contract")
    }

    static func scope() async throws {
        var calls = 0
        let client = service { _ in calls += 1; throw URLError(.badServerResponse) }
        for selection in [item(xuid: "OTHER_XUID"), item(entity: "OTHER_ENTITY"), item(id: "not-a-guid")] {
            try await rejects({ _ = try await client.delete(item: selection, credentials: account, services: config()) }, "Invalid account/ID binding was accepted")
        }
        for credential in [SignedInAccount(xuid: account.xuid, gamertag: "", sessionTicket: "", entityToken: account.entityToken, entityId: account.entityId, expiresAt: .distantPast), SignedInAccount(xuid: account.xuid, gamertag: "", sessionTicket: "", entityToken: "bad\r\ntoken", entityId: account.entityId, expiresAt: .distantFuture)] {
            try await rejects({ _ = try await client.delete(item: item(), credentials: credential, services: config()) }, "Invalid session was accepted")
        }
        try check(calls == 0, "Invalid preflight state sent a request")
    }

    static func preflightMismatch() async throws {
        for value in [details(row(id: otherID)), details(row(owner: "OTHER_OWNER")), details(row(type: "GameVariant")), .object(["Items": .array([])])] {
            var calls: [String] = []
            let client = service { request in calls.append(request.url!.path); return try json(value) }
            try await rejects({ _ = try await client.delete(item: item(), credentials: account, services: config()) }, "Fresh identity/owner/type mismatch was accepted")
            try check(!calls.contains("/test/delete"), "Preflight mismatch dispatched deletion")
        }
        let client = service { _ in try json(.object(["error": .string("NotAuthorized")]), status: 401) }
        try await rejects({ _ = try await client.delete(item: item(), credentials: account, services: config()) }, "Authentication refusal was accepted")
    }

    static func gametypes() async throws {
        var mutations = 0
        let client = service { request in
            switch request.url?.path {
            case "/test/detail": return try json(details(row(type: "GameVariant")))
            case "/test/delete": mutations += 1; return .init()
            default: return try json(listing())
            }
        }
        let result = try await client.delete(item: item(kind: .gametype), credentials: account, services: config())
        try check(result.confirmedAbsent && mutations == 1, "Owned gametype was not deleted exactly once and reconciled")

        mutations = 0
        let mismatch = service { request in
            if request.url?.path == "/test/delete" { mutations += 1 }
            return try json(details(row(type: "MapVariant")))
        }
        try await rejects({ _ = try await mismatch.delete(item: item(kind: .gametype), credentials: account, services: config()) }, "Gametype selection accepted a fresh map of the same ID")
        try check(mutations == 0, "Changed content kind dispatched a deletion")
    }

    static func alreadyAbsent() async throws {
        for missing in [JSONValue.object(["data": .object([:])]), .object(["Error": .object(["Error": .string("ItemNotFound")])])] {
            var paths: [String] = []
            let client = service { request in
                paths.append(request.url!.path)
                return try json(request.url?.path == "/test/detail" ? missing : listing())
            }
            let result = try await client.delete(item: item(), credentials: account, services: config())
            try check(result.outcome == .alreadyAbsent && result.confirmedAbsent && paths == ["/test/detail", "/test/list"], "Preflight absence dispatched mutation or lost confirmed state")
        }
    }

    static func unverifiedPreflight() async throws {
        for incomplete in [listing([], count: .number(1)), listing([row()]), listing([], extra: ["HasMore": .bool(true)]), .object(["Error": .string("NotAuthorized")])] {
            var mutations = 0
            let client = service { request in
                if request.url?.path == "/test/delete" { mutations += 1 }
                return try json(request.url?.path == "/test/detail" ? .object(["data": .object([:])]) : incomplete)
            }
            try await rejects({ _ = try await client.delete(item: item(), credentials: account, services: config()) }, "Unverified preflight absence was allowed")
            try check(mutations == 0, "Unavailable metadata still dispatched mutation")
        }
    }

    static func staleAcknowledgement() async throws {
        for ack in [DeletionProtocol.Reply(), try json(.object(["code": .number(200), "data": .object([:])])), .init(data: Data("{malformed".utf8))] {
            var mutations = 0
            let client = service { request in
                switch request.url?.path {
                case "/test/detail": return try json(details())
                case "/test/delete": mutations += 1; return ack
                default: return try json(listing([row()]))
                }
            }
            let result = try await client.delete(item: item(), credentials: account, services: config())
            try check(result.outcome == .uncertain && !result.confirmedAbsent && mutations == 1, "HTTP acknowledgement/malformed response plus stale list became success or retried")
        }
    }

    static func refused() async throws {
        let refusals = [try json(.object(["Error": .object(["Error": .string("NotAuthorized")])])), try json(.object(["error": .string("Denied")])), try json(.object(["code": .number(403), "data": .object([:])])), DeletionProtocol.Reply(status: 403)]
        for refusal in refusals {
            var mutations = 0
            let client = service { request in
                switch request.url?.path {
                case "/test/detail": return try json(details())
                case "/test/delete": mutations += 1; return refusal
                default: return try json(listing([row()]))
                }
            }
            let result = try await client.delete(item: item(), credentials: account, services: config())
            try check(result.outcome == .notDeleted && !result.confirmedAbsent && mutations == 1, "Explicit refusal became success or a retry")
        }
    }

    static func reconciledAbsence() async throws {
        for mode in 0..<3 {
            var mutations = 0
            let client = service { request in
                switch request.url?.path {
                case "/test/detail": return try json(details())
                case "/test/delete":
                    mutations += 1
                    if mode == 0 { return .init(status: 403) }
                    if mode == 1 { throw URLError(.networkConnectionLost) }
                    return .init(data: Data("<html>proxy</html>".utf8))
                default: return try json(listing([row(id: otherID, type: "GameVariant")]))
                }
            }
            let result = try await client.delete(item: item(), credentials: account, services: config())
            try check(result.confirmedAbsent && result.outcome == (mode == 0 ? .alreadyAbsent : .deleted) && mutations == 1, "Complete absence was not reconciled after refusal/ambiguous reply")
        }
    }

    static func allTypes() async throws {
        let client = service { request in
            switch request.url?.path {
            case "/test/detail": return try json(details())
            case "/test/delete": return .init()
            default: return try json(listing([row(type: "GameVariant")]))
            }
        }
        let result = try await client.delete(item: item(), credentials: account, services: config())
        try check(result.outcome == .uncertain && !result.confirmedAbsent, "Map-only filtering falsely proved catalog-ID absence")
    }

    static func exactNotFound() async throws {
        let missingReplies = [try json(.object(["error": .string("ItemNotFound")])), try json(.object(["data": .object(["Error": .object(["Error": .string("ItemNotFound")])])])), try json(.object(["error": .string("ItemNotFound")]), status: 404)]
        for missing in missingReplies {
            var detailsCount = 0, mutations = 0
            let client = service { request in
                switch request.url?.path {
                case "/test/detail": detailsCount += 1; return detailsCount == 1 ? try json(details()) : missing
                case "/test/delete": mutations += 1; throw URLError(.timedOut)
                default: return try json(listing([], count: .number(1)))
                }
            }
            let result = try await client.delete(item: item(), credentials: account, services: config())
            try check(result.confirmedAbsent && result.outcome == .deleted && mutations == 1 && detailsCount == 2, "Exact provider ItemNotFound was not reconciled")
        }
        for unverified in [DeletionProtocol.Reply(status: 404), try json(.object(["data": .object([:])])), try json(.object(["code": .number(404)])), try json(.object(["error": .string("NotAuthorized")]))] {
            var detailCalls = 0
            let client = service { request in
                if request.url?.path == "/test/detail" { detailCalls += 1; return detailCalls == 1 ? try json(details()) : unverified }
                return request.url?.path == "/test/delete" ? .init() : try json(listing([], count: .number(1)))
            }
            let result = try await client.delete(item: item(), credentials: account, services: config())
            try check(result.outcome == .uncertain && !result.confirmedAbsent, "Generic missing/error metadata was accepted as exact ItemNotFound")
        }
    }

    static func incompleteList() async throws {
        let invalids = [listing([], count: .number(1)), listing([], count: .null), listing([], extra: ["ContinuationToken": .string("opaque")]), listing([row(id: otherID, owner: "OTHER_OWNER")]), listing([row(id: otherID), row(id: otherID)]), .object(["Error": .string("Denied")]), .object(["data": .string("malformed")])]
        for invalid in invalids {
            let client = service { request in
                if request.url?.path == "/test/detail" { return try json(details()) }
                return request.url?.path == "/test/delete" ? .init() : try json(invalid)
            }
            let result = try await client.delete(item: item(), credentials: account, services: config())
            try check(!result.confirmedAbsent && result.outcome == .uncertain, "Incomplete/malformed/foreign listing proved absence")
        }
    }

    static func lostReply() async throws {
        let sensitive = "SENSITIVE_CREDENTIAL_URL_BODY"
        for status in [408, 500, 502, 307] {
            var mutations = 0
            let client = service { request in
                if request.url?.path == "/test/detail" { return try json(details()) }
                if request.url?.path == "/test/delete" { mutations += 1; return .init(data: Data(sensitive.utf8), status: status) }
                throw URLError(.timedOut, userInfo: [NSLocalizedDescriptionKey: sensitive])
            }
            let result = try await client.delete(item: item(), credentials: account, services: config())
            try check(result.outcome == .uncertain && !result.confirmedAbsent && mutations == 1 && !result.message.contains(sensitive), "Ambiguous mutation retried, leaked errors, or became safely retryable")
        }
    }

    static func cancellation() async throws {
        var requests = 0
        let client = service { _ in requests += 1; throw URLError(.badServerResponse) }
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await client.delete(item: item(), credentials: account, services: config())
        }
        try await rejects({ _ = try await task.value }, "Cancelled preflight returned success")
        try check(requests == 0, "Cancellation before dispatch made a request")
        var mutations = 0
        let afterDispatch = service { request in
            switch request.url?.path {
            case "/test/detail": return try json(details())
            case "/test/delete": mutations += 1; throw URLError(.cancelled)
            default: throw URLError(.cancelled)
            }
        }
        let result = try await afterDispatch.delete(item: item(), credentials: account, services: config())
        try check(result.outcome == .uncertain && !result.confirmedAbsent && mutations == 1, "Cancellation after dispatch concealed possible mutation")
    }

    static func configuration() async throws {
        let old: JSONValue = .object(["upload": .string("https://mcc-production.azurefd.net/upload"), "permission": .string("https://mcc-production.azurefd.net/permission"), "source": .string("legacy")])
        let decoded = try JSONDecoder().decode(MCCServiceConfiguration.self, from: old.encoded())
        try check(decoded.itemDeletion.path == "/api/DeletePlayFabUgcItem", "Legacy settings did not acquire native delete route")
        let custom = try config()
        try check(try JSONDecoder().decode(MCCServiceConfiguration.self, from: JSONEncoder().encode(custom)) == custom, "Settings roundtrip lost deletion route")
        let resolved = try await ServiceDiscovery().resolve(account: account, saved: custom)
        try check(resolved.itemDeletion == custom.itemDeletion, "Saved service validation lost custom deletion route")
        let paths = [("MCCAzureFunctions_UploadFile", "/upload"), ("MCCAzureFunctions_GetUploadPermission", "/permission"), ("PlayFab_GetPublishedItem", "/native-detail"), ("MCCAzureFunctions_GetPlayFabUgcItem", "/old-detail"), ("PlayFab_DeleteDraftItem", "/native-delete")]
        let endpointRows: [String: JSONValue] = Dictionary(uniqueKeysWithValues: paths.map { ($0, .object(["AuthorityId": .string("api"), "Path": .string($1)])) })
        let discovery: JSONValue = .object(["Authorities": .object(["api": .object(["Scheme": .number(2), "Port": .number(443), "Hostname": .string("mcc-production.azurefd.net")])]), "Endpoints": .object(endpointRows)])
        let discovered = try MCCServiceConfiguration.discovered(from: discovery, source: "native fixture")
        try check(discovered.itemDeletion.path == "/native-delete" && discovered.itemLookup.path == "/native-detail", "Discovery ignored exact native route keys")
        for address in ["http://mcc-production.azurefd.net/delete", "https://attacker.example/delete", "https://mcc-production.azurefd.net/delete?token=x"] {
            var invalid = old.object!; invalid["itemDeletion"] = .string(address)
            do { _ = try JSONDecoder().decode(MCCServiceConfiguration.self, from: JSONValue.object(invalid).encoded()); throw Failure(description: "Decoded malicious deletion endpoint was accepted") }
            catch let error as Failure { throw error }
            catch { }
        }
    }

    static func reconcile() async throws {
        for present in [false, true] {
            var requests: [String] = []
            let client = service { request in
                requests.append(request.url!.path)
                return try json(listing(present ? [row()] : []))
            }
            let result = try await client.reconcile(item: item(), credentials: account, services: config())
            try check(result.confirmedAbsent == !present && result.outcome == (present ? .uncertain : .deleted), "Read-only reconciliation did not preserve the actual absence state")
            try check(result.itemID == itemID && result.accountXUID == account.xuid && result.accountEntityID == account.entityId && requests == ["/test/list"], "Read-only reconciliation mutated or lost account/ID binding")
        }
        var calls = 0
        let client = service { _ in calls += 1; return try json(listing()) }
        try await rejects({ _ = try await client.reconcile(item: item(entity: "OTHER_ENTITY"), credentials: account, services: config()) }, "Reconciliation accepted another account's selection")
        try check(calls == 0, "Cross-account reconciliation issued a request")
    }
}

#if FILESHARE_DELETION_STANDALONE_TESTS
@main struct FileShareDeletionStandaloneTests {
    static func main() async throws {
        try await DeletionCases.contract()
        try await DeletionCases.scope()
        try await DeletionCases.preflightMismatch()
        try await DeletionCases.alreadyAbsent()
        try await DeletionCases.unverifiedPreflight()
        try await DeletionCases.staleAcknowledgement()
        try await DeletionCases.refused()
        try await DeletionCases.reconciledAbsence()
        try await DeletionCases.allTypes()
        try await DeletionCases.exactNotFound()
        try await DeletionCases.incompleteList()
        try await DeletionCases.lostReply()
        try await DeletionCases.cancellation()
        try await DeletionCases.reconcile()
        try await DeletionCases.configuration()
        try await DeletionCases.gametypes()
        print("File Share deletion tests: 16 cases passed; mocked native contract, account binding, fresh owned-file preflight, map and gametype kinds, complete-list/all-type absence, exact ItemNotFound, refusals, stale/ambiguous replies, one mutation, read-only reconciliation, cancellation and settings migration; no live mutation or network.")
    }
}
#endif
#endif
