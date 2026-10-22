import Foundation
import MCCPublisherCore

@main struct SharedUploadJournalTests {
    private struct Failure: Error, CustomStringConvertible { let description: String }
    static let firstID = "00000000-0000-4000-8000-000000000001"
    static let secondID = "00000000-0000-4000-8000-000000000002"
    static let hash = String(repeating: "a", count: 64)
    static func check(_ value: Bool, _ message: String) throws { if !value { throw Failure(description: message) } }
    static func rejects(_ action: () throws -> Void, _ message: String) throws {
        do { try action() } catch { return }; throw Failure(description: message)
    }
    static func fixture(_ action: (URL) throws -> Void) throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("MCCSharedUploadJournal-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: folder) }
        try action(folder.appendingPathComponent("uploads.json"))
    }
    @discardableResult static func record(_ journal: inout PendingSharedUploads, account: String = "12345", entity: String = "entity", kind: VariantKind = .map, fileID: String = firstID) throws -> PendingSharedUploads.Entry {
        try journal.record(accountXUID: account, accountEntityID: entity, coreSHA256: hash, kind: kind, fileID: fileID, title: "Synthetic file")
    }
    static func restartAndScope() throws {
        try fixture { url in
            var journal = try PendingSharedUploads(url: url)
            let entry = try record(&journal)
            try record(&journal, account: "54321")
            try record(&journal, entity: "different")
            try record(&journal, kind: .gametype)
            var restored = try PendingSharedUploads(url: url)
            try check(restored.pending(accountXUID: "12345", accountEntityID: "entity").count == 2, "Restart lost map/gametype recovery or mixed accounts")
            try check(restored.pending(accountXUID: "12345", accountEntityID: "entity", coreSHA256: hash, kind: .map)?.fileID == entry.fileID, "Restart lost prepared upload identity")
            try rejects({ _ = try record(&restored, fileID: secondID) }, "Restart allowed a second upload ID for an unresolved file")
            try check(try record(&restored).fileID == firstID, "Idempotent record changed prepared identity")
        }
    }
    static func matchingAndTargetedCleanup() throws {
        try fixture { url in
            var journal = try PendingSharedUploads(url: url)
            let entry = try record(&journal)
            let matching = FileShareItem(id: secondID, title: "Remote title", accountEntityID: "entity", accountXUID: "12345", kind: .map, protocolFileName: firstID)
            try check(entry.matches(matching), "Exact prepared upload identity was not recognized")
            for item in [FileShareItem(id: secondID, title: "Same title", accountEntityID: "other", accountXUID: "12345", protocolFileName: firstID), FileShareItem(id: secondID, title: "Same title", accountEntityID: "entity", accountXUID: "54321", protocolFileName: firstID), FileShareItem(id: secondID, title: "Same title", accountEntityID: "entity", accountXUID: "12345", kind: .gametype, protocolFileName: firstID), FileShareItem(id: secondID, title: "Synthetic file", accountEntityID: "entity", accountXUID: "12345", protocolFileName: secondID)] {
                try check(!entry.matches(item), "Different account, kind, or upload ID could retire an uncertain upload")
            }
            try record(&journal, kind: .gametype)
            try journal.remove(entry)
            try check(journal.pending(accountXUID: "12345", accountEntityID: "entity").map(\.kind) == [.gametype], "Cleanup lost another content kind")
            _ = try record(&journal, fileID: secondID)
            try journal.remove(entry)
            try check(journal.pending(accountXUID: "12345", accountEntityID: "entity", coreSHA256: hash, kind: .map)?.fileID == secondID, "Stale cleanup retired a newly prepared attempt")
        }
    }
    static func persistenceFailure() throws {
        try fixture { url in
            var journal = try PendingSharedUploads(url: url)
            let entry = try record(&journal)
            let parent = url.deletingLastPathComponent()
            let moved = parent.deletingLastPathComponent().appendingPathComponent("MCCMovedSharedUpload-\(UUID().uuidString)")
            try FileManager.default.moveItem(at: parent, to: moved)
            defer { try? FileManager.default.moveItem(at: moved, to: parent); try? FileManager.default.removeItem(at: moved) }
            try rejects({ _ = try record(&journal, kind: .gametype) }, "Failed journal save appeared durable")
            try rejects({ try journal.remove(entry) }, "Failed cleanup retired a pending upload")
            try check(journal.pending(accountXUID: "12345", accountEntityID: "entity").count == 1, "Failed persistence changed the protected in-memory set")
        }
    }
    static func validationAndPrivacy() throws {
        try fixture { url in
            var journal = try PendingSharedUploads(url: url)
            try record(&journal)
            let raw = try Data(contentsOf: url)
            let text = String(decoding: raw, as: UTF8.self)
            try check(!text.contains("entityToken") && !text.contains("sessionTicket") && !text.contains("Authorization") && !text.contains("sourceURL"), "Recovery record included credentials or source paths")
            try check((try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber)?.intValue == 0o600, "Recovery record was not private")
            var object = try JSONSerialization.jsonObject(with: raw) as! [String: Any]
            var rows = object["intents"] as! [[String: Any]]
            rows[0]["entityToken"] = "SHOULD_BE_REJECTED"
            object["intents"] = rows
            try JSONSerialization.data(withJSONObject: object).write(to: url)
            try rejects({ _ = try PendingSharedUploads(url: url) }, "Journal accepted an unexpected credential field")
            try Data("{broken".utf8).write(to: url)
            try rejects({ _ = try PendingSharedUploads(url: url) }, "Corrupt recovery record silently became empty")
            try Data(repeating: 32, count: 4 * 1024 * 1024 + 1).write(to: url)
            try rejects({ _ = try PendingSharedUploads(url: url) }, "Oversized recovery record bypassed its bound")
        }
    }
    static func main() throws {
        try restartAndScope(); try matchingAndTargetedCleanup(); try persistenceFailure(); try validationAndPrivacy()
        print("Shared upload journal tests: 4 cases passed; restart protection, account/entity/kind/upload-ID matching, targeted cleanup, failed-save preservation, bounded strict records and credential exclusion; no network or mutation.")
    }
}
