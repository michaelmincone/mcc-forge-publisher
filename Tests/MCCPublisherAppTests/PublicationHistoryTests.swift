import Foundation

#if HISTORY_STANDALONE_TESTS
private enum PublicationHistoryCases {
    private struct Failure: Error, CustomStringConvertible { let description: String }
    private static let accountA = "24680"
    private static let accountB = "13579"
    private static let hashA = String(repeating: "a", count: 64)
    private static let hashB = String(repeating: "b", count: 64)

    private static func check(_ condition: Bool, _ message: String) throws {
        if !condition { throw Failure(description: message) }
    }
    private static func rejects(_ operation: () throws -> Void, _ message: String) throws {
        do { try operation() } catch { return }
        throw Failure(description: message)
    }
    private static func withHistoryURL(_ body: (URL) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("MCCPublisherHistoryTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }
        try body(directory.appendingPathComponent("publications.json"))
    }
    private static func receipt(itemID: String = "00000000-0000-4000-8000-000000000001", hash: String = hashA,
                                verified: Bool = false) -> PublicationReceipt {
        PublicationReceipt(itemID: itemID, title: "Synthetic map", publishedAt: Date(timeIntervalSince1970: 1_700_000_000),
            downloadVerified: verified, fileSHA256: hash)
    }

    static func diskReload() throws {
        try withHistoryURL { url in
            var history = try PublicationHistory(url: url)
            try check(history.receipt(accountXUID: accountA, coreSHA256: hashA) == nil, "A new history invented a publication")
            try history.record(receipt(), accountXUID: accountA)
            let reloaded = try PublicationHistory(url: url)
            let restored = reloaded.receipt(accountXUID: accountA, coreSHA256: hashA)
            try check(restored?.itemID == receipt().itemID, "Restarting lost the receipt that prevents a duplicate upload")
            try check(restored?.fileSHA256 == hashA && restored?.downloadVerified == false, "Reloading changed receipt validation state")
        }
    }

    static func accountAndCoreBinding() throws {
        try withHistoryURL { url in
            var history = try PublicationHistory(url: url)
            try history.record(receipt(), accountXUID: accountA)
            try check(history.receipt(accountXUID: accountB, coreSHA256: hashA) == nil, "Another account inherited a receipt")
            try check(history.receipt(accountXUID: accountA, coreSHA256: hashB) == nil, "Changed core bytes inherited an old receipt")
            let second = receipt(itemID: "00000000-0000-4000-8000-000000000002", hash: hashB)
            try history.record(second, accountXUID: accountB)
            let reloaded = try PublicationHistory(url: url)
            try check(reloaded.receipt(accountXUID: accountA, coreSHA256: hashA)?.itemID == receipt().itemID, "Adding another account overwrote the first receipt")
            try check(reloaded.receipt(accountXUID: accountB, coreSHA256: hashB)?.itemID == second.itemID, "Account/core lookup selected the wrong catalog item")
        }
    }

    static func verificationUpdatesSameItem() throws {
        try withHistoryURL { url in
            var history = try PublicationHistory(url: url)
            try history.record(receipt(), accountXUID: accountA)
            try history.record(receipt(verified: true), accountXUID: accountA)
            let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
            let document = try decoder.decode(PublicationHistory.Document.self, from: Data(contentsOf: url))
            try check(document.receipts.count == 1, "A stored-byte verification created a duplicate history entry")
            let reloaded = try PublicationHistory(url: url)
            try check(reloaded.receipt(accountXUID: accountA, coreSHA256: hashA)?.downloadVerified == true,
                      "The verification result did not persist on the existing item")
        }
    }

    static func privatePermissions() throws {
        try withHistoryURL { url in
            var history = try PublicationHistory(url: url)
            try history.record(receipt(), accountXUID: accountA)
            let written = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber
            try check(written?.intValue == 0o600, "The written receipt history is not mode 0600")
            try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path)
            _ = try PublicationHistory(url: url)
            let restored = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber
            try check(restored?.intValue == 0o600, "Loading existing history did not restore mode 0600")
        }
    }

    static func corruptHistoryRejects() throws {
        try withHistoryURL { url in
            let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
            let unsupported = PublicationHistory.Document(schemaVersion: 2, receipts: [])
            let invalid = PublicationHistory.Document(schemaVersion: 1, receipts: [
                .init(accountXUID: accountA, receipt: receipt(hash: "invalid hash"))
            ])
            for data in [Data("{broken json".utf8), try encoder.encode(unsupported), try encoder.encode(invalid)] {
                try data.write(to: url)
                try rejects({ _ = try PublicationHistory(url: url) }, "Corrupt or unsupported history silently became empty and could allow duplicate uploads")
            }
        }
    }

    static func failedWriteRetainsSessionReceipt() throws {
        try withHistoryURL { url in
            var history = try PublicationHistory(url: url)
            // Removing the private temporary parent reliably makes saving fail,
            // regardless of the current user's permission to chmod test files.
            try FileManager.default.removeItem(at: url.deletingLastPathComponent())
            try rejects({ try history.record(receipt(), accountXUID: accountA) }, "Saving into a missing parent unexpectedly succeeded")
            try check(history.receipt(accountXUID: accountA, coreSHA256: hashA)?.itemID == receipt().itemID,
                      "A failed disk save lost the in-session receipt and could allow another upload")
            try check(!FileManager.default.fileExists(atPath: url.path), "The failed write fixture unexpectedly created history")
        }
    }
}

@main
struct PublicationHistoryStandaloneTests {
    static func main() throws {
        try PublicationHistoryCases.diskReload()
        try PublicationHistoryCases.accountAndCoreBinding()
        try PublicationHistoryCases.verificationUpdatesSameItem()
        try PublicationHistoryCases.privatePermissions()
        try PublicationHistoryCases.corruptHistoryRejects()
        try PublicationHistoryCases.failedWriteRetainsSessionReceipt()
        print("Publication history tests: 6 cases passed; disk reload, account/core binding, verification update, mode 0600, corrupt-history rejection, and failed-save duplicate protection; no authentication or network.")
    }
}
#endif
