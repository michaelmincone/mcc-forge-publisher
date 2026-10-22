import Foundation
import MCCPublisherCore

@main struct LibraryModelStandaloneTests {
    private struct Failure: Error, CustomStringConvertible { let description: String }
    private static func check(_ condition: Bool, _ message: String) throws {
        if !condition { throw Failure(description: message) }
    }
    private static let account = SignedInAccount(xuid: "24680", gamertag: "Synthetic", sessionTicket: "FAKE_SESSION", entityToken: "FAKE_ENTITY", entityId: "SYNTHETIC_ENTITY", expiresAt: .distantFuture)
    private static let firstID = "00000000-0000-4000-8000-000000000001"
    private static let secondID = "00000000-0000-4000-8000-000000000002"
    private static let firstHash = String(repeating: "a", count: 64)
    private static let secondHash = String(repeating: "b", count: 64)
    private static func fixture(_ action: (URL) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("MCCLibraryRecoveryTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        try action(directory)
    }
    private static func recordIntent(_ journal: inout PendingSharedUploads, id: String, hash: String) throws {
        try journal.record(accountXUID: account.xuid, accountEntityID: account.entityId, coreSHA256: hash, kind: .map, fileID: id, title: "Synthetic \(id)")
    }
    private static func ownedItem(_ id: String) -> FileShareItem {
        FileShareItem(id: id, title: "Synthetic remote file", accountEntityID: account.entityId, accountXUID: account.xuid, protocolFileName: id)
    }
    @MainActor private static func receiptFailureRepairAndReconciliation() throws {
        try fixture { directory in
            let intentsURL = directory.appendingPathComponent("shared-upload-intents.json")
            let receiptsURL = directory.appendingPathComponent("publications.json")
            var intents = try PendingSharedUploads(url: intentsURL)
            try recordIntent(&intents, id: firstID, hash: firstHash)
            try recordIntent(&intents, id: secondID, hash: secondHash)
            let model = PublisherAppModel(preview: false, applicationSupportDirectory: directory)
            model.account = account
            try check(model.historyAvailable, "A new isolated receipt history was unavailable")

            // The model already owns a history instance. Blocking rename makes
            // record keep an acknowledged receipt in RAM while disk persistence fails.
            try FileManager.default.createDirectory(at: receiptsURL, withIntermediateDirectories: false)
            model.reconcileSharedUploads(in: [ownedItem(firstID)], account: account)
            try check(!model.historyAvailable, "A failed receipt persistence did not pause uploads")
            try check(try PendingSharedUploads(url: intentsURL).pending(accountXUID: account.xuid, accountEntityID: account.entityId).count == 2, "Failed receipt persistence retired an upload intent")

            try FileManager.default.removeItem(at: receiptsURL)
            try JSONValue.object(["schemaVersion": .number(1), "receipts": .array([])]).encoded().write(to: receiptsURL)
            model.reloadPublicationHistoryIfNeeded()
            try check(!model.historyAvailable, "Reload discarded the existing failed-write history or declared it durable without persistence")
            model.reconcileSharedUploads(in: [ownedItem(secondID)], account: account)
            let repaired = try PublicationHistory(url: receiptsURL)
            try check(model.historyAvailable, "Successful recovery did not restore upload availability")
            try check(repaired.receipt(accountXUID: account.xuid, coreSHA256: firstHash)?.itemID == firstID && repaired.receipt(accountXUID: account.xuid, coreSHA256: secondHash)?.itemID == secondID, "Recovery lost the earlier acknowledged RAM receipt while reloading disk history")

            model.reconcileSharedUploads(in: [ownedItem(firstID), ownedItem(secondID)], account: account)
            try check(model.historyAvailable && (try PendingSharedUploads(url: intentsURL).pending(accountXUID: account.xuid, accountEntityID: account.entityId).isEmpty), "Repair and reconciliation did not clear recovered intents")
        }
    }
    @MainActor private static func journalCleanupFailureKeepsReceiptsAvailable() throws {
        try fixture { directory in
            let intentsURL = directory.appendingPathComponent("shared-upload-intents.json")
            let backupURL = directory.appendingPathComponent("preserved-intents.json")
            let receiptsURL = directory.appendingPathComponent("publications.json")
            var intents = try PendingSharedUploads(url: intentsURL)
            try recordIntent(&intents, id: firstID, hash: firstHash)
            let model = PublisherAppModel(preview: false, applicationSupportDirectory: directory)
            model.account = account
            try FileManager.default.moveItem(at: intentsURL, to: backupURL)
            try FileManager.default.createDirectory(at: intentsURL, withIntermediateDirectories: false)
            model.reconcileSharedUploads(in: [ownedItem(firstID)], account: account)
            try check(model.historyAvailable && (try PublicationHistory(url: receiptsURL).receipt(accountXUID: account.xuid, coreSHA256: firstHash)?.itemID == firstID), "Intent cleanup failure marked successfully persisted receipts unavailable")
            try check(model.sharedUploadJournalMessage?.contains("recovery record could not be cleared") == true, "Journal cleanup failure was not reported separately")
            try FileManager.default.removeItem(at: intentsURL)
            try FileManager.default.moveItem(at: backupURL, to: intentsURL)
            model.reconcileSharedUploads(in: [ownedItem(firstID)], account: account)
            try check(model.historyAvailable && (try PendingSharedUploads(url: intentsURL).pending(accountXUID: account.xuid, accountEntityID: account.entityId).isEmpty), "Repaired journal cleanup did not finish read-only recovery")
        }
    }
    @MainActor private static func unavailableHistoryCanReloadAfterRepair() throws {
        try fixture { directory in
            let receiptsURL = directory.appendingPathComponent("publications.json")
            try FileManager.default.createDirectory(at: receiptsURL, withIntermediateDirectories: false)
            let model = PublisherAppModel(preview: false, applicationSupportDirectory: directory)
            model.account = account
            try check(!model.historyAvailable, "Invalid initial history was treated as an empty receipt store")
            try FileManager.default.removeItem(at: receiptsURL)
            try JSONValue.object(["schemaVersion": .number(1), "receipts": .array([])]).encoded().write(to: receiptsURL)
            model.reloadPublicationHistoryIfNeeded()
            try check(model.historyAvailable, "Explicit refresh could not reload a repaired missing history instance")
        }
    }
    @MainActor static func main() async throws {
        let model = PublisherAppModel()
        try check(model.isPreview, "Model tests require --preview-library to avoid account access")
        try check(model.account?.entityId == "preview" && model.fileShareItems.count == 5, "Preview did not use its isolated sample library")
        try check(!model.canUpload && !model.canDeleteSelection && model.operationInProgress, "Preview enabled an account mutation")

        model.searchText = "survive floor"
        try check(model.filteredFileShareItems.map(\.title) == ["Vanishing Floor"], "Search did not combine title and description terms")
        model.searchText = ""
        model.kindFilter = .gametypes
        try check(model.filteredFileShareItems.count == 2 && model.filteredFileShareItems.allSatisfy { $0.kind == .gametype }, "Gametype filter mixed content kinds")

        let all = Set(model.fileShareItems.map(\.id))
        model.fileShareSelection = all
        model.trimSelection()
        try check(model.selectedFileShareItems.count == 2 && model.fileShareSelection.count == 2, "Filtering retained hidden mutation targets")
        model.searchText = "missing item"
        model.trimSelection()
        try check(model.fileShareSelection.isEmpty && model.selectedFileShareItems.isEmpty, "Search retained a hidden selection")

        model.searchText = "Skybranch"
        model.kindFilter = .all
        model.trimSelection()
        try check(model.filteredFileShareItems.map(\.title) == ["Skybranch"] && model.fileShareSelection.isEmpty, "Single-library search restored an old hidden selection")
        model.searchText = ""
        model.trimSelection()
        try check(model.filteredFileShareItems.count == 5 && model.fileShareSelection.isEmpty, "Clearing search did not restore the library without old mutation targets")
        try check(model.transferResults.isEmpty && model.fileShareSavedURL == nil, "Read-only filtering manufactured a completed operation")

        let before = model.account
        await model.signIn()
        await model.signOut()
        await model.publish()
        await model.deleteSelectedFileShareItem()
        try check(model.account == before && model.uploadQueue.isEmpty && model.transferResults.isEmpty, "Preview reached a real account operation")
        try check(model.batchFraction == 0 && model.batchTitle == nil, "Empty preview manufactured transfer progress")
        try receiptFailureRepairAndReconciliation()
        try journalCleanupFailureKeepsReceiptsAvailable()
        try unavailableHistoryCanReloadAfterRepair()
        print("Library model tests: 8 cases passed; isolated preview, single-library search/filter/selection boundaries, disabled account operations, real receipt-write failure and repair, preserved RAM receipts, separate journal-cleanup failures and missing-history reload; no live authentication or network.")
    }
}
