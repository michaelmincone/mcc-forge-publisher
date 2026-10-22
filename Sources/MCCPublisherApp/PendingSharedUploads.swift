import Foundation
import Darwin
#if !SHARED_UPLOAD_JOURNAL_STANDALONE_TESTS
import MCCPublisherCore
#endif

/// A prepared shared upload can have succeeded even if its reply was lost.
/// This journal stores identity only and never authorizes an automatic resend.
struct PendingSharedUploads {
    struct Entry: Codable, Equatable {
        let accountXUID: String
        let accountEntityID: String
        let coreSHA256: String
        let kind: VariantKind
        let fileID: String
        let title: String
        let createdAt: Date
        var key: String { accountXUID + ":" + accountEntityID + ":" + kind.rawValue + ":" + coreSHA256 }
        func matches(_ item: FileShareItem) -> Bool {
            item.accountXUID == accountXUID && item.accountEntityID == accountEntityID && item.kind == kind && item.protocolFileName == fileID
        }
    }
    private struct Document: Codable { let schemaVersion: Int; let intents: [Entry] }
    private var entries: [Entry]
    let url: URL
    private static let maximumSize = 4 * 1024 * 1024
    private static let maximumEntries = 10_000

    init(url: URL) throws {
        guard url.isFileURL else { throw Self.invalid() }
        self.url = url
        guard FileManager.default.fileExists(atPath: url.path) else { entries = []; return }
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard attributes[.type] as? FileAttributeType == .typeRegular,
              let size = attributes[.size] as? NSNumber, size.uint64Value <= Self.maximumSize else { throw Self.invalid() }
        let raw = try Data(contentsOf: url)
        guard raw.count <= Self.maximumSize, Self.onlyIdentityFields(raw) else { throw Self.invalid() }
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let document = try decoder.decode(Document.self, from: raw)
        guard document.schemaVersion == 1, document.intents.count <= Self.maximumEntries,
              document.intents.allSatisfy(Self.valid), Set(document.intents.map(\.key)).count == document.intents.count else { throw Self.invalid() }
        entries = document.intents
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    func pending(accountXUID: String, accountEntityID: String) -> [Entry] {
        entries.filter { $0.accountXUID == accountXUID && $0.accountEntityID == accountEntityID }
    }
    func pending(accountXUID: String, accountEntityID: String, coreSHA256: String, kind: VariantKind) -> Entry? {
        pending(accountXUID: accountXUID, accountEntityID: accountEntityID).first { $0.coreSHA256 == coreSHA256 && $0.kind == kind }
    }

    @discardableResult
    mutating func record(accountXUID: String, accountEntityID: String, coreSHA256: String, kind: VariantKind, fileID: String, title: String) throws -> Entry {
        let entry = Entry(accountXUID: accountXUID, accountEntityID: accountEntityID, coreSHA256: coreSHA256,
            kind: kind, fileID: fileID.lowercased(), title: Self.displayTitle(title), createdAt: Date())
        guard Self.valid(entry) else { throw Self.invalid() }
        if let existing = entries.first(where: { $0.key == entry.key }) {
            guard existing.fileID == entry.fileID else {
                throw PublisherError.service("An earlier upload of this file needs checking. Refresh Shared Files or review the pending upload before trying again.")
            }
            return existing
        }
        let updated = entries + [entry]
        try persist(updated)
        entries = updated
        return entry
    }

    mutating func remove(_ entry: Entry) throws {
        let updated = entries.filter { !($0.key == entry.key && $0.fileID == entry.fileID) }
        guard updated.count != entries.count else { return }
        try persist(updated)
        entries = updated
    }

    private func persist(_ updated: [Entry]) throws {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]; encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(Document(schemaVersion: 1, intents: updated))
        guard updated.count <= Self.maximumEntries, data.count <= Self.maximumSize else { throw Self.saveFailure() }
        let stage = url.deletingLastPathComponent().appendingPathComponent(".shared-upload-intents-\(UUID().uuidString).tmp")
        defer { try? FileManager.default.removeItem(at: stage) }
        guard FileManager.default.createFile(atPath: stage.path, contents: data, attributes: [.posixPermissions: 0o600]) else { throw Self.saveFailure() }
        let handle = try FileHandle(forWritingTo: stage)
        do { try handle.synchronize(); try handle.close() } catch { try? handle.close(); throw Self.saveFailure() }
        guard rename(stage.path, url.path) == 0 else { throw Self.saveFailure() }
    }
    private static func valid(_ entry: Entry) -> Bool {
        UInt64(entry.accountXUID) != nil && !entry.accountXUID.isEmpty && entry.accountXUID.count <= 20 && entry.accountXUID.utf8.allSatisfy { (48...57).contains($0) }
            && !entry.accountEntityID.isEmpty && entry.accountEntityID.utf8.count <= 128
            && !entry.accountEntityID.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
            && entry.coreSHA256.count == 64 && entry.coreSHA256.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
            && UUID(uuidString: entry.fileID) != nil && entry.fileID == entry.fileID.lowercased()
            && entry.title.utf8.count <= 4096 && !entry.title.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
            && entry.createdAt.timeIntervalSince1970.isFinite
    }
    private static func displayTitle(_ value: String) -> String {
        var result = value.unicodeScalars.map { CharacterSet.controlCharacters.contains($0) ? " " : String($0) }.joined()
        while result.utf8.count > 4096 { result.removeLast() }
        return result
    }
    private static func onlyIdentityFields(_ data: Data) -> Bool {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              Set(object.keys) == ["schemaVersion", "intents"], let rows = object["intents"] as? [[String: Any]], rows.count <= maximumEntries else { return false }
        let allowed: Set<String> = ["accountXUID", "accountEntityID", "coreSHA256", "kind", "fileID", "title", "createdAt"]
        return rows.allSatisfy { Set($0.keys) == allowed }
    }
    private static func invalid() -> PublisherError { .protocolError("Shared upload recovery records could not be read safely. Shared uploads are paused to prevent duplicates.") }
    private static func saveFailure() -> PublisherError { .service("The shared upload recovery record could not be saved. No new upload was started.") }
}
