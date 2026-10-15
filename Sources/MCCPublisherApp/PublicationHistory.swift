import Foundation
import Darwin
#if !HISTORY_STANDALONE_TESTS
import MCCPublisherCore
#endif

/// Public catalog information only. Authentication remains in the app's Keychain.
struct PublicationHistory {
    struct Entry: Codable {
        let accountXUID: String
        let receipt: PublicationReceipt
    }

    struct Document: Codable {
        let schemaVersion: Int
        let receipts: [Entry]
    }

    let url: URL
    private var entries: [Entry]

    init(url: URL) throws {
        self.url = url
        if FileManager.default.fileExists(atPath: url.path) {
            let size = try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber
            guard let size, size.uint64Value <= 4 * 1024 * 1024 else { throw Self.invalidHistory() }
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let document = try decoder.decode(Document.self, from: Data(contentsOf: url))
            guard document.schemaVersion == 1, document.receipts.count <= 10_000,
                  document.receipts.allSatisfy({ Self.valid($0) }) else { throw Self.invalidHistory() }
            entries = document.receipts
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        } else { entries = [] }
    }

    func receipt(accountXUID: String, coreSHA256: String) -> PublicationReceipt? {
        entries.filter { $0.accountXUID == accountXUID && $0.receipt.fileSHA256 == coreSHA256 }
            .max { $0.receipt.publishedAt < $1.receipt.publishedAt }?.receipt
    }

    mutating func record(_ receipt: PublicationReceipt, accountXUID: String) throws {
        let entry = Entry(accountXUID: accountXUID, receipt: receipt)
        guard Self.valid(entry) else { throw Self.invalidHistory() }
        var updated = entries.filter { !($0.accountXUID == accountXUID && $0.receipt.itemID == receipt.itemID) }
        updated.append(entry)
        // A failed disk write must still prevent duplicate uploads during this app session.
        entries = updated
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        let data = try encoder.encode(Document(schemaVersion: 1, receipts: updated))
        guard updated.count <= 10_000, data.count <= 4 * 1024 * 1024 else {
            throw PublisherError.service("The publication receipt could not be saved because publication history is full.")
        }
        let temporaryURL = url.deletingLastPathComponent().appendingPathComponent(".publications-\(UUID().uuidString).tmp")
        defer { try? FileManager.default.removeItem(at: temporaryURL) }
        guard FileManager.default.createFile(atPath: temporaryURL.path, contents: data, attributes: [.posixPermissions: 0o600]) else {
            throw PublisherError.service("The publication receipt could not be saved.")
        }
        guard rename(temporaryURL.path, url.path) == 0 else {
            throw PublisherError.service("The publication receipt could not be saved.")
        }
    }

    private static func valid(_ entry: Entry) -> Bool {
        let receipt = entry.receipt
        return UInt64(entry.accountXUID) != nil && !receipt.itemID.isEmpty && receipt.itemID.count <= 128
            && receipt.itemID.rangeOfCharacter(from: .controlCharacters) == nil
            && receipt.fileSHA256.count == 64
            && receipt.fileSHA256.allSatisfy { ("0"..."9").contains($0) || ("a"..."f").contains($0) }
    }

    private static func invalidHistory() -> PublisherError {
        .protocolError("Publication history could not be read. Upload is paused to avoid duplicate entries.")
    }
}
