import Foundation
import AppKit
import UniformTypeIdentifiers
import CryptoKit
import MCCPublisherCore

@MainActor
final class PublisherAppModel: ObservableObject {
    @Published var account: SignedInAccount?
    @Published var map: ReachMapDocument?
    @Published var busy = false
    @Published var error = false
    @Published var message = "Sign in and choose a Reach map to begin."
    @Published var receipt: PublicationReceipt?
    @Published private(set) var historyAvailable = true
    @Published private(set) var fileShareItems: [FileShareItem] = []
    @Published var fileShareSelectionID: String?
    @Published private(set) var fileShareBusy = false
    @Published private(set) var fileShareLoading = false
    @Published private(set) var fileShareHasLoaded = false
    @Published private(set) var fileShareNeedsSignIn = false
    @Published private(set) var fileShareError = false
    @Published private(set) var fileShareMessage = "Sign in to browse your MCC File Share."
    @Published private(set) var fileShareWarning: String?
    @Published private(set) var fileShareSavedURL: URL?
    @Published private(set) var fileShareSavedTitle: String?
    @Published private(set) var fileShareSavedSHA256: String?
    @Published private(set) var fileShareDeletionMessage: String?
    @Published private(set) var fileShareDeletionHasWarning = false
    @Published private(set) var fileShareDeletionJournalAvailable = false
    @Published private(set) var fileShareDeletionJournalMessage: String?
    private let auth = AuthService()
    private let loginWindow = MicrosoftLoginWindow()
    private var restored = false
    private var services: MCCServiceConfiguration?
    private let statusURL: URL
    private var history: PublicationHistory?
    private var deletionIntents: PendingFileShareDeletions?
    private var selectedCoreSHA256: String?
    private var fileShareAccountScope: String?
    private var confirmedAbsentItems: [String: FileShareDeletionResult] = [:]
    private var pendingDeletionHistoryCleanup: [String: FileShareDeletionResult] = [:]
    private var pendingUncertainDeletions: [String: FileShareItem] = [:]
    private var uncertainDeletionWarnings: [String: String] = [:]
    private var deletionStatusBase: String?
    private var deletionStatusIsWarning = false
    private var deletionHistoryWarning: String?
    private var deletionRefreshWarning: String?

    var operationInProgress: Bool { busy || fileShareBusy }
    var selectedFileShareItem: FileShareItem? {
        fileShareItems.first { $0.id == fileShareSelectionID }
    }

    init() {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!.appendingPathComponent("MCCForgePublisher")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path)
        statusURL = dir.appendingPathComponent("status.json")
        do { history = try PublicationHistory(url: dir.appendingPathComponent("publications.json")) }
        catch { historyAvailable = false; setStatus("history_unavailable", "Publication history could not be read. Upload is paused to avoid duplicate entries.", failed: true) }
        loadDeletionJournalIfNeeded()
        if let raw = try? Data(contentsOf: dir.appendingPathComponent("services.json")), let loaded = try? JSONDecoder().decode(MCCServiceConfiguration.self, from: raw),
           (try? MCCServiceConfiguration.validate(loaded.upload)) != nil, (try? MCCServiceConfiguration.validate(loaded.permission)) != nil {
            services = loaded
        }
        if let raw = CommandLine.arguments.dropFirst().first, raw.hasSuffix(".mvar") { select(URL(fileURLWithPath: raw)) }
    }
    func restore() async {
        guard !restored else { return }; restored = true
        busy = true; defer { busy = false }
        if await auth.savedSignInNeedsApproval() {
            setStatus("keychain_approval", "This version of the app needs permission to use your saved sign-in. Enter your Mac password if macOS asks. It won't ask again until the app is updated.")
        }
        do {
            account = try await auth.restoreSession()
            resetFileShare()
            restoreMatchingReceipt()
            if let account { await loadFileShare(for: account) }
        } catch AuthError.signInRequired {
            setStatus("sign_in_required", "Sign in again to reconnect your MCC account.")
        } catch {
            // Keep the reason: a refusal that also stops a fresh sign-in needs more than signing in again.
            setStatus("sign_in_required", "Sign in again to reconnect your MCC account. Reconnecting failed: \(error.localizedDescription)")
        }
    }
    func signIn() async {
        guard !operationInProgress else { return }; busy = true; defer { busy = false }
        do {
            setStatus("signing_in", "Opening Microsoft sign-in…")
            let challenge = try await auth.beginSignIn()
            let callback = try await loginWindow.authorize(challenge)
            setStatus("connecting", "Connecting your Xbox profile to MCC…")
            account = try await auth.completeSignIn(callback: callback)
            resetFileShare()
            restoreMatchingReceipt()
            if let account { await loadFileShare(for: account) }
        } catch { fail(error) }
    }
    func signOut() async {
        guard !operationInProgress else { return }
        busy = true; defer { busy = false }
        do {
            try await auth.signOut()
            account = nil; receipt = nil
            resetFileShare()
            setStatus("signed_out", "Signed out.")
        } catch { fail(error) }
    }
    func chooseMap() {
        guard !operationInProgress else { return }
        let panel = NSOpenPanel(); panel.allowedContentTypes = [UTType(filenameExtension: "mvar") ?? .data]
        panel.canChooseDirectories = false; panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url { select(url) }
    }
    func select(_ url: URL) {
        guard !operationInProgress else { return }
        do {
            let selected = try ReachMapDocument.load(from: url)
            map = selected
            selectedCoreSHA256 = SHA256.hash(data: Data(selected.bytes.prefix(selected.embeddedLength)))
                .map { String(format: "%02x", $0) }.joined()
            restoreMatchingReceipt()
        } catch { fail(error) }
    }
    func chooseConfiguration() {
        guard !operationInProgress else { return }
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.json]; panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            do {
                let data = try Data(contentsOf: url); let value = try JSONDecoder().decode(JSONValue.self, from: data)
                let config: MCCServiceConfiguration
                if value["upload"].string != nil {
                    let saved = try JSONDecoder().decode(MCCServiceConfiguration.self, from: data)
                    config = try MCCServiceConfiguration(upload: saved.upload, permission: saved.permission, itemLookup: saved.itemLookup, itemListing: saved.itemListing, itemDeletion: saved.itemDeletion, sandbox: saved.sandbox, source: saved.source)
                } else { config = try MCCServiceConfiguration.discovered(from: value, source: url.lastPathComponent) }
                services = config
                let out = statusURL.deletingLastPathComponent().appendingPathComponent("services.json")
                try JSONEncoder().encode(config).write(to: out, options: .atomic)
                setStatus("configured", "MCC service configuration loaded.")
            } catch { fail(error) }
        }
    }
    func publish() async {
        guard !operationInProgress, historyAvailable, let map, let account else { return }
        if receipt != nil { return }
        if let hash = selectedCoreSHA256, let saved = history?.receipt(accountXUID: account.xuid, coreSHA256: hash) {
            receipt = saved
            setReceiptStatus()
            return
        }
        busy = true; defer { busy = false }
        do {
            setStatus("preparing", "Preparing the map and checking MCC upload permission…")
            // Discovery will use the verified live service config supplied by the protocol layer.
            let config = try await ServiceDiscovery().resolve(account: account, saved: services)
            services = config
            let plan = try FreshMapMetadata.makePlan(map: map, account: account)
            setStatus("uploading", "Uploading \(map.title)…")
            let service = PublisherService()
            let published = try await service.upload(plan: plan, credentials: account, services: config)
            receipt = published
            do { try history?.record(published, accountXUID: account.xuid) }
            catch {
                setStatus("published_history_error", "Published, but the receipt could not be saved. Check your MCC File Share before uploading this map again.", failed: true)
                return
            }
            setStatus("published", "Published. Checking the File Share download…")
            do {
                let verified = try await service.verifyDownload(receipt: published, credentials: account, services: config)
                receipt = verified
                do { try history?.record(verified, accountXUID: account.xuid) }
                catch {
                    setStatus("verified_history_error", "Stored file bytes match. The updated receipt could not be saved. Xbox compatibility still needs to be checked in MCC.", failed: true)
                    return
                }
                setReceiptStatus()
            } catch { setStatus("published", "Published. The stored file check is pending. Check Download can retry this check without uploading again.") }
        } catch { fail(error) }
    }
    func checkDownload() async {
        guard !operationInProgress, let receipt, let account else { return }
        busy = true; defer { busy = false }
        do {
            setStatus("checking_download", "Checking the stored File Share bytes…")
            let config = try await ServiceDiscovery().resolve(account: account, saved: services)
            services = config
            let verified = try await PublisherService().verifyDownload(receipt: receipt, credentials: account, services: config)
            self.receipt = verified
            do { try history?.record(verified, accountXUID: account.xuid) }
            catch {
                setStatus("verified_history_error", "Stored file bytes match. The updated receipt could not be saved. Xbox compatibility still needs to be checked in MCC.", failed: true)
                return
            }
            setReceiptStatus()
        } catch {
            setStatus("download_check_failed", "Published item retained. Stored file check failed: \(error.localizedDescription)", failed: true)
        }
    }
    func refreshFileShare() async {
        guard !operationInProgress, let account else { return }
        await loadFileShare(for: account, isExplicitRefresh: true)
    }
    func downloadSelectedFileShareItem() async {
        guard !operationInProgress, let account, let item = selectedFileShareItem else { return }
        fileShareBusy = true
        defer { fileShareBusy = false }
        let panel = NSSavePanel()
        panel.title = "Download Map Variant"
        panel.message = "Save \(item.title) from your MCC File Share."
        panel.prompt = "Save"
        panel.allowedContentTypes = [UTType(filenameExtension: "mvar") ?? .data]
        panel.allowsOtherFileTypes = false
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        panel.nameFieldStringValue = item.suggestedFilename
        guard panel.runModal() == .OK, let url = panel.url else { return }
        fileShareSavedURL = nil; fileShareSavedTitle = nil; fileShareSavedSHA256 = nil
        fileShareError = false
        fileShareMessage = "Downloading \(item.title)…"
        do {
            let credentials = try await currentFileShareCredentials(expected: account)
            let config = try await ServiceDiscovery().resolve(account: credentials, saved: services)
            guard self.account?.xuid == account.xuid else { return }
            services = config
            let download = try await FileShareService().download(item: item, credentials: credentials, services: config)
            guard self.account?.xuid == account.xuid else { return }
            fileShareMessage = "Saving \(item.title)…"
            try await Task.detached(priority: .userInitiated) { try download.save(to: url) }.value
            guard self.account?.xuid == account.xuid else { return }
            fileShareSavedURL = url; fileShareSavedTitle = item.title; fileShareSavedSHA256 = download.sha256
            fileShareMessage = "Saved \(item.title). Map file structure checked; in-game compatibility has not been checked."
        } catch {
            guard self.account?.xuid == account.xuid else { return }
            fileShareError = true
            fileShareMessage = "Download failed: \(error.localizedDescription)"
        }
    }
    func revealDownloadedFile() {
        guard let url = fileShareSavedURL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }
    func deleteSelectedFileShareItem() async {
        guard !operationInProgress, let capturedAccount = account, let capturedItem = selectedFileShareItem else { return }
        guard fileShareDeletionJournalAvailable, deletionIntents != nil else {
            fileShareError = true
            fileShareMessage = "Delete is unavailable because its recovery records could not be loaded. Refresh to retry loading them."
            return
        }
        guard capturedItem.accountXUID == capturedAccount.xuid, capturedItem.accountEntityID == capturedAccount.entityId else {
            fileShareError = true
            fileShareMessage = "The selected map does not belong to the connected account. Refresh your File Share."
            return
        }
        // Hold the same operation guard from confirmation through reconciliation.
        // Nothing is requested, including session renewal, until Delete is chosen.
        fileShareBusy = true
        defer { fileShareBusy = false }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Delete this map from your File Share?"
        alert.informativeText = "“\(capturedItem.title)”\nGame: \(capturedItem.game ?? "Not provided by MCC")\nItem ID: \(capturedItem.id)\n\nThis removes the shared copy from your MCC File Share. Local downloads are kept. Download a backup first if you want one. This app cannot undo the deletion."
        let cancel = alert.addButton(withTitle: "Cancel")
        cancel.keyEquivalent = "\r"
        let delete = alert.addButton(withTitle: "Delete from File Share")
        delete.hasDestructiveAction = true
        delete.keyEquivalent = ""
        guard alert.runModal() == .alertSecondButtonReturn else { return }

        deletionStatusBase = nil; deletionStatusIsWarning = false; deletionRefreshWarning = nil
        updateDeletionStatus()
        fileShareError = false
        fileShareMessage = "Deleting “\(capturedItem.title)” from your File Share…"
        let previouslyPending = pendingUncertainDeletions[capturedItem.id] != nil
        var recordedIntent = false
        do {
            let credentials = try await currentFileShareCredentials(expected: capturedAccount)
            let config = try await ServiceDiscovery().resolve(account: credentials, saved: services)
            guard accountMatches(capturedAccount) else { return }
            services = config
            // The durable intent allows a later launch/account reconnection to
            // reconcile a request whose response is lost. It proves no deletion.
            try recordDeletionIntent(capturedItem)
            recordedIntent = true
            let result = try await FileShareDeletionService().delete(item: capturedItem, credentials: credentials, services: config)
            guard accountMatches(capturedAccount) else { return }
            guard result.itemID == capturedItem.id, result.accountXUID == capturedAccount.xuid,
                  result.accountEntityID == capturedAccount.entityId else {
                pendingUncertainDeletions[capturedItem.id] = capturedItem
                uncertainDeletionWarnings[capturedItem.id] = "Deletion of “\(capturedItem.title)” could not be confirmed because MCC's result did not match the selected item and account. Publication receipts were kept. Refresh will check this item without sending another deletion request."
                fileShareMessage = "Deletion is unconfirmed."
                updateDeletionStatus()
                return
            }
            guard result.confirmedAbsent else {
                switch result.outcome {
                case .uncertain:
                    pendingUncertainDeletions[capturedItem.id] = capturedItem
                    uncertainDeletionWarnings[capturedItem.id] = "“\(capturedItem.title)”: \(result.message) Publication receipts were kept. Refresh checks this item without sending another deletion request."
                    fileShareMessage = "Deletion is unconfirmed. Publication receipts were kept; no automatic deletion retry was made."
                default:
                    if !previouslyPending { clearConcludedDeletionIntent(capturedItem, reason: "MCC refused the deletion request") }
                    deletionStatusBase = "“\(capturedItem.title)”: \(result.message)"
                    deletionStatusIsWarning = true
                    fileShareMessage = "The map was not deleted. Publication receipts were kept."
                }
                updateDeletionStatus()
                return
            }
            guard applyConfirmedDeletion(result, item: capturedItem, account: capturedAccount) else { return }
            // Keep the confirmed result visible in its own banner if this refresh fails.
            await loadFileShare(for: credentials, holdingBusy: true)
        } catch {
            guard accountMatches(capturedAccount) else { return }
            if let failure = error as? PublisherError, case .authentication = failure { fileShareNeedsSignIn = true }
            // The service throws only before its dispatch boundary. Do not
            // discard a journal entry from an earlier uncertain attempt.
            if recordedIntent && !previouslyPending { clearConcludedDeletionIntent(capturedItem, reason: "No deletion request was sent") }
            deletionStatusBase = "Deletion was not sent for “\(capturedItem.title)”. \(error.localizedDescription) Publication receipts were kept."
            deletionStatusIsWarning = true
            fileShareMessage = "No deletion request was sent."
            updateDeletionStatus()
        }
    }
    private func loadFileShare(for requestAccount: SignedInAccount, holdingBusy: Bool = false, isExplicitRefresh: Bool = false) async {
        guard !fileShareBusy || holdingBusy else { return }
        fileShareBusy = true; fileShareLoading = true; fileShareError = false
        fileShareMessage = "Loading your MCC File Share…"
        defer { if !holdingBusy { fileShareBusy = false }; fileShareLoading = false }
        if isExplicitRefresh { loadDeletionJournalIfNeeded() }
        var retriedHistoryCleanup = false
        do {
            let credentials = try await currentFileShareCredentials(expected: requestAccount)
            let config = try await ServiceDiscovery().resolve(account: credentials, saved: services)
            guard account?.xuid == requestAccount.xuid else { return }
            services = config
            if isExplicitRefresh {
                await reconcilePendingUncertainDeletions(credentials: credentials, services: config)
                guard accountMatches(requestAccount) else { return }
            }
            retryPendingDeletionHistoryCleanup(for: requestAccount, retryUnavailableHistory: isExplicitRefresh)
            retriedHistoryCleanup = true
            let listing = try await FileShareService().list(credentials: credentials, services: config)
            guard account?.xuid == requestAccount.xuid else { return }
            // MCC may briefly return a stale catalog entry after confirming removal.
            // A confirmed-deleted ID stays unavailable for this account in this session.
            fileShareItems = listing.items.filter { confirmedAbsentItems[$0.id] == nil }
            let suppressed = listing.items.count - fileShareItems.count
            deletionRefreshWarning = suppressed == 0 ? nil : "MCC still listed \(suppressed) confirmed-deleted item\(suppressed == 1 ? "" : "s"). Those entries are hidden from this browser."
            updateDeletionStatus()
            fileShareHasLoaded = true
            fileShareWarning = listing.isComplete ? nil : (listing.warning ?? "Only part of your File Share could be loaded. Refresh to try again.")
            if !fileShareItems.contains(where: { $0.id == fileShareSelectionID }) {
                fileShareSelectionID = fileShareItems.first?.id
            }
            let count = fileShareItems.count
            if listing.isComplete {
                fileShareMessage = count == 0 ? "No map variants are on this account’s File Share." : "\(count) map variant\(count == 1 ? "" : "s") on your File Share."
            } else {
                fileShareMessage = "\(count) map variant\(count == 1 ? "" : "s") loaded. Results are incomplete."
            }
        } catch {
            guard account?.xuid == requestAccount.xuid else { return }
            if !retriedHistoryCleanup {
                retryPendingDeletionHistoryCleanup(for: requestAccount, retryUnavailableHistory: isExplicitRefresh)
            }
            if let failure = error as? PublisherError, case .authentication = failure { fileShareNeedsSignIn = true }
            fileShareError = true
            fileShareMessage = fileShareHasLoaded ? "Refresh failed. Previous results are shown. \(error.localizedDescription)" : "File Share could not be loaded: \(error.localizedDescription)"
            if !confirmedAbsentItems.isEmpty {
                deletionRefreshWarning = "The File Share refresh failed. Confirmed-deleted items remain hidden. \(error.localizedDescription)"
                updateDeletionStatus()
            }
        }
    }
    private func resetFileShare() {
        let nextScope = account.map { $0.xuid + ":" + $0.entityId }
        if fileShareAccountScope != nextScope {
            confirmedAbsentItems.removeAll(); pendingDeletionHistoryCleanup.removeAll()
            pendingUncertainDeletions.removeAll(); uncertainDeletionWarnings.removeAll()
            deletionStatusBase = nil; deletionStatusIsWarning = false
            deletionHistoryWarning = nil; deletionRefreshWarning = nil
            fileShareDeletionMessage = nil; fileShareDeletionHasWarning = false
        }
        fileShareAccountScope = nextScope
        restoreJournaledDeletionIntents()
        fileShareItems = []; fileShareSelectionID = nil
        fileShareHasLoaded = false; fileShareError = false; fileShareWarning = nil; fileShareNeedsSignIn = false
        fileShareSavedURL = nil; fileShareSavedTitle = nil; fileShareSavedSHA256 = nil
        fileShareMessage = account == nil ? "Sign in to browse your MCC File Share." : "Your File Share is ready to load."
    }
    private func accountMatches(_ expected: SignedInAccount) -> Bool {
        account?.xuid == expected.xuid && account?.entityId == expected.entityId
    }
    private func loadDeletionJournalIfNeeded() {
        guard deletionIntents == nil else { return }
        do {
            deletionIntents = try PendingFileShareDeletions(url: statusURL.deletingLastPathComponent().appendingPathComponent("deletion-intents.json"))
            fileShareDeletionJournalAvailable = true
            fileShareDeletionJournalMessage = nil
            restoreJournaledDeletionIntents()
        } catch {
            fileShareDeletionJournalAvailable = false
            fileShareDeletionJournalMessage = "Delete is disabled because deletion recovery records could not be read. Refresh will retry loading them. \(error.localizedDescription)"
        }
    }
    private func restoreJournaledDeletionIntents() {
        guard let account, let deletionIntents else { return }
        for item in deletionIntents.items(accountXUID: account.xuid, accountEntityID: account.entityId) {
            guard confirmedAbsentItems[item.id] == nil, pendingUncertainDeletions[item.id] == nil else { continue }
            pendingUncertainDeletions[item.id] = item
            uncertainDeletionWarnings[item.id] = "A saved deletion intent for “\(item.title)” needs checking. It does not prove the map was deleted. Refresh checks this item without sending another deletion request."
        }
        updateDeletionStatus()
    }
    private func recordDeletionIntent(_ item: FileShareItem) throws {
        guard var journal = deletionIntents, fileShareDeletionJournalAvailable else {
            throw PublisherError.service("Deletion recovery records are unavailable. Refresh to retry loading them.")
        }
        try journal.record(item)
        deletionIntents = journal
    }
    private func clearConcludedDeletionIntent(_ item: FileShareItem, reason: String) {
        do {
            guard deletionIntents != nil else { throw PublisherError.service("Deletion recovery records are unavailable.") }
            try deletionIntents?.remove(itemID: item.id, accountXUID: item.accountXUID, accountEntityID: item.accountEntityID)
            pendingUncertainDeletions.removeValue(forKey: item.id)
            uncertainDeletionWarnings.removeValue(forKey: item.id)
        } catch {
            pendingUncertainDeletions[item.id] = item
            uncertainDeletionWarnings[item.id] = "\(reason) for “\(item.title)”, but its recovery record could not be cleared. \(error.localizedDescription) Refresh checks this item without sending another deletion request."
        }
    }
    @discardableResult
    private func applyConfirmedDeletion(_ result: FileShareDeletionResult, item: FileShareItem, account expected: SignedInAccount) -> Bool {
        guard accountMatches(expected), result.confirmedAbsent,
              result.itemID == item.id, result.accountXUID == expected.xuid,
              result.accountEntityID == expected.entityId,
              item.accountXUID == expected.xuid, item.accountEntityID == expected.entityId else { return false }
        confirmedAbsentItems[result.itemID] = result
        pendingDeletionHistoryCleanup[result.itemID] = result
        pendingUncertainDeletions.removeValue(forKey: result.itemID)
        uncertainDeletionWarnings.removeValue(forKey: result.itemID)
        fileShareItems.removeAll { $0.id == result.itemID && $0.accountXUID == result.accountXUID && $0.accountEntityID == result.accountEntityID }
        if fileShareSelectionID == result.itemID { fileShareSelectionID = fileShareItems.first?.id }
        deletionStatusBase = "“\(item.title)”: \(result.message)"
        deletionStatusIsWarning = false
        updateDeletionStatus()
        return true
    }
    private func reconcilePendingUncertainDeletions(credentials: SignedInAccount, services config: MCCServiceConfiguration) async {
        guard accountMatches(credentials) else { return }
        for (id, capturedItem) in Array(pendingUncertainDeletions).sorted(by: { $0.key < $1.key }) {
            guard capturedItem.accountXUID == credentials.xuid, capturedItem.accountEntityID == credentials.entityId else { continue }
            fileShareMessage = "Checking whether “\(capturedItem.title)” was deleted…"
            do {
                // Reconcile performs only read-only ownership/presence queries.
                // It must never dispatch another DeletePlayFabUgcItem request.
                let result = try await FileShareDeletionService().reconcile(item: capturedItem, credentials: credentials, services: config)
                guard accountMatches(credentials) else { return }
                guard result.itemID == id, result.accountXUID == credentials.xuid,
                      result.accountEntityID == credentials.entityId else {
                    uncertainDeletionWarnings[id] = "Deletion of “\(capturedItem.title)” remains unconfirmed because MCC's result did not match the captured item and account. Publication receipts were kept. Refresh checks again without deleting again."
                    continue
                }
                if result.confirmedAbsent {
                    applyConfirmedDeletion(result, item: capturedItem, account: credentials)
                } else {
                    uncertainDeletionWarnings[id] = "“\(capturedItem.title)”: \(result.message) Publication receipts were kept. Refresh checks again without sending another deletion request."
                }
            } catch {
                guard accountMatches(credentials) else { return }
                if let failure = error as? PublisherError, case .authentication = failure { fileShareNeedsSignIn = true }
                uncertainDeletionWarnings[id] = "Deletion of “\(capturedItem.title)” remains unconfirmed. \(error.localizedDescription) Publication receipts were kept. Refresh checks again without sending another deletion request."
            }
        }
        updateDeletionStatus()
    }
    private func retryPendingDeletionHistoryCleanup(for expected: SignedInAccount, retryUnavailableHistory: Bool) {
        guard accountMatches(expected), !pendingDeletionHistoryCleanup.isEmpty else { return }
        // An explicit Refresh may recover history that failed initial validation.
        // Never reload an existing instance: it can hold unsaved upload receipts
        // that still need to prevent duplicate publication in this app session.
        if history == nil, retryUnavailableHistory {
            history = try? PublicationHistory(url: statusURL.deletingLastPathComponent().appendingPathComponent("publications.json"))
        }
        guard history != nil else {
            deletionHistoryWarning = "Publication history is unavailable. Receipt cleanup is pending and uploads remain paused. Refresh will retry cleanup."
            restoreMatchingReceipt()
            updateDeletionStatus()
            return
        }
        var historyFailures: [String] = []
        var journalFailures: [String] = []
        for (id, result) in Array(pendingDeletionHistoryCleanup) where result.accountXUID == expected.xuid && result.accountEntityID == expected.entityId {
            do {
                try history?.removeConfirmedDeletion(result)
            } catch {
                historyFailures.append(error.localizedDescription)
                continue
            }
            do {
                guard deletionIntents != nil else { throw PublisherError.service("Deletion recovery records are unavailable.") }
                try deletionIntents?.remove(itemID: result.itemID, accountXUID: result.accountXUID, accountEntityID: result.accountEntityID)
                pendingDeletionHistoryCleanup.removeValue(forKey: id)
            } catch { journalFailures.append(error.localizedDescription) }
        }
        if historyFailures.isEmpty { historyAvailable = true }
        var cleanupWarnings: [String] = []
        if let failure = historyFailures.first {
            cleanupWarnings.append("Receipt cleanup is pending. Existing upload protection was kept. \(historyAvailable ? "" : "Uploads remain paused. ")Refresh will retry cleanup without deleting again. \(failure)")
        }
        if let failure = journalFailures.first {
            cleanupWarnings.append("Deletion recovery records could not be cleared after the matching receipts were cleaned. Refresh will retry local cleanup without deleting again. \(failure)")
        }
        deletionHistoryWarning = cleanupWarnings.isEmpty ? nil : cleanupWarnings.joined(separator: " ")
        restoreMatchingReceipt()
        updateDeletionStatus()
    }
    private func updateDeletionStatus() {
        let pendingWarnings = uncertainDeletionWarnings.keys.sorted().compactMap { uncertainDeletionWarnings[$0] }
        let parts = [deletionStatusBase, deletionHistoryWarning, deletionRefreshWarning].compactMap { $0 } + pendingWarnings
        fileShareDeletionMessage = parts.isEmpty ? nil : parts.joined(separator: " ")
        fileShareDeletionHasWarning = deletionStatusIsWarning || deletionHistoryWarning != nil || deletionRefreshWarning != nil || !pendingWarnings.isEmpty
    }
    private func currentFileShareCredentials(expected: SignedInAccount) async throws -> SignedInAccount {
        guard account?.xuid == expected.xuid, account?.entityId == expected.entityId else {
            throw PublisherError.authentication("The connected account changed. Refresh your File Share before continuing.")
        }
        guard expected.expiresAt <= Date().addingTimeInterval(60) else { return expected }
        fileShareMessage = "Renewing your MCC session…"
        let renewed: SignedInAccount
        do {
            guard let restored = try await auth.restoreSession() else { throw AuthError.signInRequired }
            renewed = restored
        } catch {
            fileShareNeedsSignIn = true
            throw PublisherError.authentication("Your MCC session could not be renewed. Use Sign in again to reconnect. \(error.localizedDescription)")
        }
        guard account?.xuid == expected.xuid else { throw AuthError.signInRequired }
        account = renewed
        if renewed.xuid != expected.xuid || renewed.entityId != expected.entityId {
            resetFileShare()
            restoreMatchingReceipt()
            throw PublisherError.authentication("The connected account changed. Refresh to load its File Share.")
        }
        fileShareNeedsSignIn = false
        return renewed
    }
    private func restoreMatchingReceipt() {
        receipt = nil
        if let account, let hash = selectedCoreSHA256 {
            receipt = history?.receipt(accountXUID: account.xuid, coreSHA256: hash)
        }
        if !historyAvailable {
            setStatus("history_unavailable", "Publication history could not be read. Upload is paused to avoid duplicate entries.", failed: true)
        } else if receipt != nil { setReceiptStatus() }
        else if map != nil {
            setStatus("map_selected", account == nil ? "Map verified. Sign in to publish it." : "Map verified. Ready to publish.")
        } else { setStatus(account == nil ? "signed_out" : "signed_in", account == nil ? "Sign in and choose a Reach map to begin." : "Signed in. Choose a Reach map to publish.") }
    }
    private func setReceiptStatus() {
        if receipt?.downloadVerified == true {
            setStatus("stored_bytes_verified", "Published. Stored map bytes match the upload. Xbox download acceptance still needs to be checked in MCC.")
        } else {
            setStatus("previous_publication", "This map is already published to this account. Check Download verifies its stored bytes without uploading again.")
        }
    }
    private func fail(_ value: Error) { setStatus("error", value.localizedDescription, failed: true) }
    private func setStatus(_ stage: String, _ text: String, failed: Bool = false) {
        message = text; error = failed
        let snapshot = JSONValue.object([
            "stage": .string(stage), "message": .string(text), "signedIn": .bool(account != nil),
            "mapSelected": .bool(map != nil), "published": .bool(receipt != nil),
            "downloadVerified": .bool(receipt?.downloadVerified ?? false), "updatedAt": .string(ISO8601DateFormatter().string(from: Date()))
        ])
        if let data = try? snapshot.encoded() { try? data.write(to: statusURL, options: .atomic); try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: statusURL.path) }
    }
}
