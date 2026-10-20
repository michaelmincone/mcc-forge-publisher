import Foundation
import Darwin
#if !DELETION_JOURNAL_STANDALONE_TESTS
import MCCPublisherCore
#endif

/// Durable deletion intent, never proof of deletion or authority to retry it.
/// Restored items are snapshots for read-only reconciliation by the service.
struct PendingFileShareDeletions {
    private struct Entry: Codable {
        let itemID: String
        let title: String
        let game: String?
        let modifiedAt: Date?
        let accountXUID: String
        let accountEntityID: String
        var key: Key { Key(accountXUID: accountXUID, accountEntityID: accountEntityID, itemID: itemID.lowercased()) }
        var item: FileShareItem {
            FileShareItem(id: itemID, title: title, game: game, modifiedAt: modifiedAt,
                          accountEntityID: accountEntityID, accountXUID: accountXUID)
        }
    }
    private struct Key: Hashable {
        let accountXUID: String
        let accountEntityID: String
        let itemID: String
    }
    private struct Document: Codable {
        let schemaVersion: Int
        let intents: [Entry]
    }
    private static let maximumSize = 4 * 1024 * 1024
    private static let maximumEntries = 10_000
    let url: URL
    private var entries: [Entry]

    init(url: URL) throws {
        guard url.isFileURL, !url.path.utf8.contains(0) else { throw Self.invalidJournal() }
        self.url = url
        guard FileManager.default.fileExists(atPath: url.path) else { entries = []; return }
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard attributes[.type] as? FileAttributeType == .typeRegular,
              let size = attributes[.size] as? NSNumber, size.uint64Value <= Self.maximumSize else { throw Self.invalidJournal() }
        let data = try Data(contentsOf: url)
        guard data.count <= Self.maximumSize, Self.hasOnlyIdentityFields(data) else { throw Self.invalidJournal() }
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let document = try decoder.decode(Document.self, from: data)
        guard document.schemaVersion == 1, document.intents.count <= Self.maximumEntries,
              document.intents.allSatisfy(Self.valid), Set(document.intents.map(\.key)).count == document.intents.count else { throw Self.invalidJournal() }
        entries = document.intents
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    func items(accountXUID: String, accountEntityID: String) -> [FileShareItem] {
        entries.filter { $0.accountXUID == accountXUID && $0.accountEntityID == accountEntityID }.map(\.item)
    }

    mutating func record(_ item: FileShareItem) throws {
        guard UUID(uuidString: item.id) != nil else { throw Self.invalidJournal() }
        let entry = Entry(itemID: item.id.lowercased(), title: Self.displayText(item.title, limit: 4096),
            game: item.game.map { Self.displayText($0, limit: 256) }, modifiedAt: item.modifiedAt,
            accountXUID: item.accountXUID, accountEntityID: item.accountEntityID)
        guard Self.valid(entry) else { throw Self.invalidJournal() }
        var updated = entries.filter { $0.key != entry.key }
        updated.append(entry)
        // Persistence is a prerequisite to the remote request. A failed record
        // cannot manufacture in-memory durability that a restart would lose.
        try persist(updated)
        entries = updated
    }

    mutating func remove(itemID: String, accountXUID: String, accountEntityID: String) throws {
        guard UUID(uuidString: itemID) != nil, Self.validAccount(accountXUID, accountEntityID) else { throw Self.invalidJournal() }
        let key = Key(accountXUID: accountXUID, accountEntityID: accountEntityID, itemID: itemID.lowercased())
        let updated = entries.filter { $0.key != key }
        guard updated.count != entries.count else { return }
        // Failed cleanup preserves the previous pending set for a read-only
        // retry; callers remove only after receipt cleanup or known refusal.
        try persist(updated)
        entries = updated
    }

    private func persist(_ updated: [Entry]) throws {
        guard updated.count <= Self.maximumEntries else { throw Self.saveFailure() }
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        let data = try encoder.encode(Document(schemaVersion: 1, intents: updated))
        guard data.count <= Self.maximumSize else { throw Self.saveFailure() }
        let temporary = url.deletingLastPathComponent().appendingPathComponent(".pending-file-share-deletions-\(UUID().uuidString).tmp")
        defer { try? FileManager.default.removeItem(at: temporary) }
        guard FileManager.default.createFile(atPath: temporary.path, contents: data, attributes: [.posixPermissions: 0o600]) else { throw Self.saveFailure() }
        do {
            let handle = try FileHandle(forWritingTo: temporary)
            do { try handle.synchronize(); try handle.close() }
            catch { try? handle.close(); throw error }
        } catch { throw Self.saveFailure() }
        guard rename(temporary.path, url.path) == 0 else { throw Self.saveFailure() }
    }

    private static func valid(_ entry: Entry) -> Bool {
        UUID(uuidString: entry.itemID) != nil && validAccount(entry.accountXUID, entry.accountEntityID)
            && entry.title.utf8.count <= 4096 && !entry.title.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
            && (entry.game == nil || (entry.game!.utf8.count <= 256 && !entry.game!.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)))
            && (entry.modifiedAt == nil || entry.modifiedAt!.timeIntervalSince1970.isFinite)
    }
    private static func validAccount(_ xuid: String, _ entity: String) -> Bool {
        !xuid.isEmpty && xuid.utf8.count <= 20 && xuid.utf8.allSatisfy { (48...57).contains($0) } && UInt64(xuid) != nil
            && !entity.isEmpty && entity.utf8.count <= 128 && !entity.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
    }
    private static func displayText(_ value: String, limit: Int) -> String {
        var text = value.unicodeScalars.map { CharacterSet.controlCharacters.contains($0) ? " " : String($0) }.joined()
        while text.utf8.count > limit { text.removeLast() }
        return text
    }
    private static func hasOnlyIdentityFields(_ data: Data) -> Bool {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              Set(object.keys) == ["schemaVersion", "intents"], let intents = object["intents"] as? [[String: Any]],
              intents.count <= maximumEntries else { return false }
        let allowed: Set<String> = ["itemID", "title", "game", "modifiedAt", "accountXUID", "accountEntityID"]
        return intents.allSatisfy { Set($0.keys).isSubset(of: allowed) }
    }
    private static func invalidJournal() -> PublisherError {
        .protocolError("Pending File Share deletion checks could not be read. Deletion is paused to protect publication history.")
    }
    private static func saveFailure() -> PublisherError {
        .service("Pending File Share deletion checks could not be saved. Previously pending checks have been kept.")
    }
}
