import Foundation

#if DELETION_JOURNAL_STANDALONE_TESTS
private final class JournalRecoveryProtocol: URLProtocol, @unchecked Sendable {
    static var handler: ((URLRequest) throws -> Data)?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            guard let handler = Self.handler else { throw URLError(.badServerResponse) }
            let data = try handler(request)
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}

private enum JournalCases {
    private struct Failure: Error, CustomStringConvertible { let description: String }
    private static let accountA = "24680"
    private static let accountB = "13579"
    private static let entityA = "SYNTHETIC_ENTITY_A"
    private static let entityB = "SYNTHETIC_ENTITY_B"
    private static let firstID = "00000000-0000-4000-8000-000000000001"
    private static let secondID = "00000000-0000-4000-8000-000000000002"
    private static func check(_ value: Bool, _ message: String) throws { if !value { throw Failure(description: message) } }
    private static func rejects(_ operation: () throws -> Void, _ message: String) throws {
        do { try operation() } catch { return }; throw Failure(description: message)
    }
    private static func fixture(_ operation: (URL) async throws -> Void) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("MCCDeletionJournalTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }
        try await operation(directory.appendingPathComponent("pending-deletions.json"))
    }
    private static func item(id: String = firstID, title: String = "Synthetic map", account: String = accountA, entity: String = entityA) -> FileShareItem {
        FileShareItem(id: id, title: title, description: "DO_NOT_PERSIST_DESCRIPTION", game: "Halo 3", baseMap: "DO_NOT_PERSIST_BASE_MAP", fileSize: 1234,
            modifiedAt: Date(timeIntervalSince1970: 1_700_000_000), accountEntityID: entity, accountXUID: account, gameEngine: "2", baseMapID: "DO_NOT_PERSIST_BASE_ID")
    }
    private static func entry(id: String = firstID, account: String = accountA, entity: String = entityA) -> JSONValue {
        .object(["itemID": .string(id), "title": .string("Synthetic map"), "game": .string("Halo 3"), "accountXUID": .string(account), "accountEntityID": .string(entity)])
    }
    private static func document(_ entries: [JSONValue], schema: Int = 1) -> JSONValue { .object(["schemaVersion": .number(Double(schema)), "intents": .array(entries)]) }

    static func roundTrip() async throws {
        try await fixture { url in
            var journal = try PendingFileShareDeletions(url: url)
            try check(journal.items(accountXUID: accountA, accountEntityID: entityA).isEmpty, "New journal invented an intent")
            let source = item()
            try journal.record(source)
            let restored = try PendingFileShareDeletions(url: url).items(accountXUID: accountA, accountEntityID: entityA)
            try check(restored.count == 1 && restored[0].id == firstID && restored[0].title == source.title && restored[0].game == "Halo 3" && restored[0].modifiedAt == source.modifiedAt, "Restart lost safe identity snapshot")
            try check(restored[0].description.isEmpty && restored[0].baseMap == nil && restored[0].fileSize == nil && restored[0].gameEngine == nil && restored[0].baseMapID == nil, "Journal restored more than identity metadata")
            let data = try Data(contentsOf: url), text = String(decoding: data, as: UTF8.self)
            try check(!text.contains("DO_NOT_PERSIST") && !text.contains("entityToken") && !text.contains("sessionTicket") && !text.contains("signature") && !text.contains("sha256"), "Journal serialized credentials, map contents or nonidentity metadata")
            try check(try JSONDecoder().decode(JSONValue.self, from: data)["schemaVersion"] == .number(1), "Journal schema is not 1")
        }
    }

    static func variantKindMigration() async throws {
        try await fixture { url in
            try document([entry()]).encoded().write(to: url)
            var journal = try PendingFileShareDeletions(url: url)
            try check(journal.items(accountXUID: accountA, accountEntityID: entityA).first?.kind == .map, "Legacy map intent lost its default kind")
            let gametype = FileShareItem(id: secondID, title: "Synthetic gametype", accountEntityID: entityA, accountXUID: accountA, kind: .gametype)
            try journal.record(gametype)
            let restored = try PendingFileShareDeletions(url: url).items(accountXUID: accountA, accountEntityID: entityA)
            try check(restored.first(where: { $0.id == firstID })?.kind == .map && restored.first(where: { $0.id == secondID })?.kind == .gametype, "Restart confused map and gametype deletion identities")
            var invalidKind = entry().object!; invalidKind["kind"] = .string("unknown")
            try document([.object(invalidKind)]).encoded().write(to: url)
            try rejects({ _ = try PendingFileShareDeletions(url: url) }, "Unknown kind was accepted as a map deletion")
        }
    }

    static func accountScope() async throws {
        try await fixture { url in
            var journal = try PendingFileShareDeletions(url: url)
            try journal.record(item())
            try journal.record(item(account: accountB))
            try journal.record(item(entity: entityB))
            try journal.record(item(id: secondID))
            let restored = try PendingFileShareDeletions(url: url)
            try check(restored.items(accountXUID: accountA, accountEntityID: entityA).count == 2, "Account/entity scope lost matching intents")
            try check(restored.items(accountXUID: accountB, accountEntityID: entityA).count == 1 && restored.items(accountXUID: accountA, accountEntityID: entityB).count == 1, "Same catalog ID overwrote another account or entity")
            try check(restored.items(accountXUID: accountB, accountEntityID: entityB).isEmpty, "Unrelated account inherited pending intent")
        }
    }

    static func upsert() async throws {
        try await fixture { url in
            var journal = try PendingFileShareDeletions(url: url)
            try journal.record(item(title: "Old title"))
            try journal.record(item(id: firstID.uppercased(), title: "Updated title"))
            let restored = try PendingFileShareDeletions(url: url).items(accountXUID: accountA, accountEntityID: entityA)
            try check(restored.count == 1 && restored[0].title == "Updated title" && restored[0].id == firstID, "Repeated intent created a duplicate or lost latest display metadata")
            try journal.record(item(title: "Line\r\nbreak\tname"))
            try check(!journal.items(accountXUID: accountA, accountEntityID: entityA)[0].title.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains), "Snapshot retained control characters")
        }
    }

    static func targetedRemove() async throws {
        try await fixture { url in
            var journal = try PendingFileShareDeletions(url: url)
            for source in [item(), item(id: secondID), item(account: accountB), item(entity: entityB)] { try journal.record(source) }
            try journal.remove(itemID: firstID.uppercased(), accountXUID: accountA, accountEntityID: entityA)
            let restored = try PendingFileShareDeletions(url: url)
            try check(restored.items(accountXUID: accountA, accountEntityID: entityA).map(\.id) == [secondID], "Removal retired the wrong map")
            try check(restored.items(accountXUID: accountB, accountEntityID: entityA).count == 1 && restored.items(accountXUID: accountA, accountEntityID: entityB).count == 1, "Targeted removal lost other account/entity intents")
            let unchanged = try Data(contentsOf: url)
            try journal.remove(itemID: firstID, accountXUID: accountA, accountEntityID: entityA)
            try check(try Data(contentsOf: url) == unchanged, "Idempotent removal rewrote unrelated pending checks")
        }
    }

    static func failedPersistence() async throws {
        try await fixture { url in
            var journal = try PendingFileShareDeletions(url: url)
            try journal.record(item())
            let original = try Data(contentsOf: url)
            let directory = url.deletingLastPathComponent()
            let moved = directory.deletingLastPathComponent().appendingPathComponent("MCCMovedJournal-\(UUID().uuidString)")
            try FileManager.default.moveItem(at: directory, to: moved)
            defer {
                if FileManager.default.fileExists(atPath: moved.path) { try? FileManager.default.moveItem(at: moved, to: directory) }
                try? FileManager.default.removeItem(at: moved)
            }
            try rejects({ try journal.record(item(id: secondID)) }, "Missing-parent record succeeded")
            try check(journal.items(accountXUID: accountA, accountEntityID: entityA).map(\.id) == [firstID], "Failed record changed in-memory pending intents")
            try rejects({ try journal.remove(itemID: firstID, accountXUID: accountA, accountEntityID: entityA) }, "Missing-parent removal succeeded")
            try check(journal.items(accountXUID: accountA, accountEntityID: entityA).map(\.id) == [firstID], "Failed remove lost the pending read-only retry")
            let movedURL = moved.appendingPathComponent(url.lastPathComponent)
            try check(try Data(contentsOf: movedURL) == original, "Failed writes altered original durable pending data")
            try FileManager.default.moveItem(at: moved, to: directory)
            try check(try PendingFileShareDeletions(url: url).items(accountXUID: accountA, accountEntityID: entityA).count == 1, "Restart after failed persistence lost the original pending intent")
            let remaining = try FileManager.default.contentsOfDirectory(atPath: directory.path)
            try check(remaining == [url.lastPathComponent], "A failed write left temporary journal artifacts")
        }
    }

    static func malformedAndBounded() async throws {
        try await fixture { url in
            var credentialField = entry().object!; credentialField["entityToken"] = .string("DO_NOT_ACCEPT_CREDENTIAL_FIELD")
            var badDate = entry().object!; badDate["modifiedAt"] = .string("not-a-date")
            var longTitle = entry().object!; longTitle["title"] = .string(String(repeating: "x", count: 4097))
            let malformed = [Data("{broken".utf8), try document([], schema: 2).encoded(), try document([entry(id: "invalid-id")]).encoded(), try document([entry(account: "not-a-decimal-xuid")]).encoded(), try document([entry(entity: "bad\r\nentity")]).encoded(), try document([entry(), entry()]).encoded(), try document([.object(credentialField)]).encoded(), try document([.object(badDate)]).encoded(), try document([.object(longTitle)]).encoded(), try document(Array(repeating: entry(), count: 10_001)).encoded(), Data(repeating: 32, count: 4 * 1024 * 1024 + 1)]
            for data in malformed {
                try data.write(to: url)
                try rejects({ _ = try PendingFileShareDeletions(url: url) }, "Malformed, unsafe, unsupported or unbounded journal silently became empty")
            }
        }
    }

    static func permissions() async throws {
        try await fixture { url in
            var journal = try PendingFileShareDeletions(url: url)
            try journal.record(item())
            let written = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber
            try check(written?.intValue == 0o600, "Pending identity journal was not written 0600")
            try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path)
            _ = try PendingFileShareDeletions(url: url)
            let loaded = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber
            try check(loaded?.intValue == 0o600, "Existing journal permissions were not repaired to 0600")
            try journal.remove(itemID: firstID, accountXUID: accountA, accountEntityID: entityA)
            let removed = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber
            try check(removed?.intValue == 0o600, "Atomic removal changed private permissions")
        }
    }

    static func restoredReadOnlyReconciliation() async throws {
        try await fixture { url in
            var journal = try PendingFileShareDeletions(url: url)
            try journal.record(item())
            let restored = try PendingFileShareDeletions(url: url).items(accountXUID: accountA, accountEntityID: entityA)[0]
            let original = try Data(contentsOf: url)
            let account = SignedInAccount(xuid: accountA, gamertag: "Synthetic", sessionTicket: "FAKE_SESSION_NOT_SAVED", entityToken: "FAKE_ENTITY_NOT_SAVED", entityId: entityA, expiresAt: .distantFuture)
            let services = try MCCServiceConfiguration(upload: URL(string: "https://mcc-production.azurefd.net/upload")!, permission: URL(string: "https://mcc-production.azurefd.net/permission")!, source: "offline journal fixture")
            for present in [false, true] {
                var requests: [String] = []
                JournalRecoveryProtocol.handler = { request in
                    requests.append(request.url!.path)
                    let rows: [JSONValue] = present ? [.object(["Id": .string(firstID), "ContentType": .string("MapVariant"), "CreatorEntity": .object(["Id": .string(entityA)])])] : []
                    return try JSONValue.object(["data": .object(["Count": .number(Double(rows.count)), "Items": .array(rows)])]).encoded()
                }
                let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [JournalRecoveryProtocol.self]
                let service = FileShareDeletionService(http: HTTPClient(session: URLSession(configuration: config)))
                let result = try await service.reconcile(item: restored, credentials: account, services: services)
                try check(result.confirmedAbsent == !present && result.outcome == (present ? .uncertain : .deleted), "Restored intent was treated as proof or lost read-only confirmation")
                try check(requests == ["/api/GetPlayFabUgcItems"] && result.accountXUID == accountA && result.accountEntityID == entityA && result.itemID == firstID, "Restart recovery issued a mutation or lost account/item scope")
                try check(try Data(contentsOf: url) == original, "Read-only reconciliation automatically removed an intent before caller receipt cleanup")
            }
        }
    }
}

@main struct PendingFileShareDeletionsStandaloneTests {
    static func main() async throws {
        try await JournalCases.roundTrip()
        try await JournalCases.variantKindMigration()
        try await JournalCases.accountScope()
        try await JournalCases.upsert()
        try await JournalCases.targetedRemove()
        try await JournalCases.failedPersistence()
        try await JournalCases.malformedAndBounded()
        try await JournalCases.permissions()
        try await JournalCases.restoredReadOnlyReconciliation()
        print("Pending deletion journal tests: 9 cases passed; kind migration, restart identity recovery, account/entity/item scope, upsert, targeted cleanup, failed-save preservation, bounded malformed JSON, private permissions and mocked read-only reconciliation; no live network or mutation.")
    }
}
#endif
