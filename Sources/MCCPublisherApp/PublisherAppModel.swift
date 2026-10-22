import Foundation
import AppKit
import UniformTypeIdentifiers
import CryptoKit
import MCCPublisherCore

@MainActor
final class PublisherAppModel: ObservableObject {
    let isPreview: Bool
    @Published var account: SignedInAccount?
    @Published var searchText = ""
    @Published var kindFilter: LibraryKindFilter = .all
    @Published var fileShareSelection: Set<String> = []
    @Published var showUploads = false
    @Published private(set) var uploadQueue: [UploadQueueEntry] = []
    @Published private(set) var transferResults: [LibraryTransferResult] = []
    @Published private(set) var batchTitle: String?
    @Published private(set) var batchCompleted = 0
    @Published private(set) var batchTotal = 0
    @Published private(set) var cancellationRequested = false
    private var uncertainUploadHashes: Set<String> = []
    @Published var busy = false
    @Published var error = false
    @Published var message = "Add Reach maps or gametypes to get started."
    @Published var receipt: PublicationReceipt?
    @Published private(set) var historyAvailable = true
    @Published private(set) var sharedUploadJournalAvailable = true
    @Published private(set) var sharedUploadJournalMessage: String?
    @Published private(set) var fileShareItems: [FileShareItem] = []
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
    private var sharedUploadIntents: PendingSharedUploads?
    private var fileShareAccountScope: String?
    private var confirmedAbsentItems: [String: FileShareDeletionResult] = [:]
    private var pendingDeletionHistoryCleanup: [String: FileShareDeletionResult] = [:]
    private var pendingUncertainDeletions: [String: FileShareItem] = [:]
    private var uncertainDeletionWarnings: [String: String] = [:]
    private var deletionStatusBase: String?
    private var deletionStatusIsWarning = false
    private var deletionHistoryWarning: String?
    private var deletionRefreshWarning: String?

    var operationInProgress: Bool { isPreview || busy || fileShareBusy }
    var libraryInteractionDisabled: Bool { busy || fileShareBusy }
    var filteredFileShareItems: [FileShareItem] {
        return fileShareItems.filter { LibrarySearch.matches($0, query: searchText, filter: kindFilter) }
    }
    var selectedFileShareItems: [FileShareItem] { filteredFileShareItems.filter { fileShareSelection.contains($0.id) } }
    var selectedFileShareItem: FileShareItem? { selectedFileShareItems.count == 1 ? selectedFileShareItems.first : nil }
    var readyUploadCount: Int { uploadQueue.filter { $0.state == .ready }.count }
    var canUpload: Bool { !operationInProgress && account != nil && readyUploadCount > 0 && historyAvailable && sharedUploadJournalAvailable }
    var canDeleteSelection: Bool { !operationInProgress && !selectedFileShareItems.isEmpty && fileShareDeletionJournalAvailable }
    var failedUploadCount: Int { uploadQueue.filter { $0.state == .failed && $0.variant != nil }.count }
    var batchFraction: Double { batchTotal == 0 ? 0 : Double(batchCompleted) / Double(batchTotal) }

    /// Overrides keep offline integration tests in an isolated support directory.
    init(preview: Bool? = nil, applicationSupportDirectory: URL? = nil) {
        isPreview = preview ?? CommandLine.arguments.contains("--preview-library")
        if isPreview {
            statusURL = FileManager.default.temporaryDirectory.appendingPathComponent("mcc-library-preview-status.json")
            account = SignedInAccount(xuid: "0", gamertag: "Library Preview", sessionTicket: "", entityToken: "", entityId: "preview", expiresAt: .distantPast)
            let titles = [("The Catacombs", "A descent beneath the surface.", VariantKind.map, "Forge World", 29481),
                          ("Vanishing Floor", "Survive as the arena falls away.", .gametype, "Survival", 11240),
                          ("Skybranch", "A path above the clouds.", .map, "Forge World", 31012),
                          ("Atomic Bowling", "One lane. Endless possibilities.", .map, "Forge World", 28320),
                          ("Arena Slayer", "Classic competition, a fresh set of rules.", .gametype, "Slayer", 8492)]
            fileShareItems = titles.enumerated().map { index, item in
                FileShareItem(id: String(format: "00000000-0000-4000-8000-%012d", index + 1), title: item.0, description: item.1,
                              game: "Halo: Reach", baseMap: item.3, fileSize: item.4, modifiedAt: Date(), accountEntityID: "preview", accountXUID: "0", kind: item.2)
            }
            fileShareHasLoaded = true; fileShareMessage = "Preview · sample files · no account connection"
            fileShareDeletionJournalAvailable = false
            return
        }
        let dir = applicationSupportDirectory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!.appendingPathComponent("MCCForgePublisher")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path)
        statusURL = dir.appendingPathComponent("status.json")
        do { history = try PublicationHistory(url: dir.appendingPathComponent("publications.json")) }
        catch { historyAvailable = false; setStatus("history_unavailable", "Publication history could not be read. Upload is paused to avoid duplicate entries.", failed: true) }
        loadDeletionJournalIfNeeded()
        loadSharedUploadJournalIfNeeded()
        if let raw = try? Data(contentsOf: dir.appendingPathComponent("services.json")), let loaded = try? JSONDecoder().decode(MCCServiceConfiguration.self, from: raw),
           (try? MCCServiceConfiguration.validate(loaded.upload)) != nil, (try? MCCServiceConfiguration.validate(loaded.permission)) != nil {
            services = loaded
        }
        for raw in CommandLine.arguments.dropFirst() where ["mvar", "bin", "game"].contains(URL(fileURLWithPath: raw).pathExtension.lowercased()) { select(URL(fileURLWithPath: raw)) }
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
    func chooseMap() { chooseFiles() }
    func chooseFiles() {
        guard !libraryInteractionDisabled else { return }
        let panel = NSOpenPanel()
        panel.title = "Add Reach maps and gametypes"
        panel.prompt = "Add Files"
        panel.allowedContentTypes = ["mvar", "bin", "game"].map { UTType(filenameExtension: $0) ?? .data }
        panel.canChooseDirectories = false; panel.allowsMultipleSelection = true
        if panel.runModal() == .OK { addFiles(panel.urls) }
    }
    func select(_ url: URL) { addFiles([url]) }
    func addFiles(_ urls: [URL]) {
        guard !libraryInteractionDisabled else { return }
        for url in urls {
            let entry = UploadQueueEntry(url: url)
            if let hash = entry.coreSHA256, uploadQueue.contains(where: { $0.coreSHA256 == hash }) { continue }
            uploadQueue.append(entry)
        }
        rebindUploadQueue()
        showUploads = true
    }
    func removeUpload(_ id: UUID) {
        guard !libraryInteractionDisabled else { return }
        uploadQueue.removeAll { $0.id == id }
    }
    func clearFinishedUploads() {
        guard !libraryInteractionDisabled else { return }
        uploadQueue.removeAll { $0.state != .ready && $0.state != .uncertain }
    }
    func retryFailedUploads() {
        guard !libraryInteractionDisabled else { return }
        for index in uploadQueue.indices where uploadQueue[index].state == .failed && uploadQueue[index].variant != nil {
            uploadQueue[index].state = .ready
            uploadQueue[index].detail = "Ready to retry in Shared Files"
        }
    }
    func cancelBatch() { cancellationRequested = true }
    func selectAllVisible() { guard !libraryInteractionDisabled else { return }; fileShareSelection = Set(filteredFileShareItems.map(\.id)) }
    func trimSelection() { fileShareSelection.formIntersection(Set(filteredFileShareItems.map(\.id))) }
    private func beginBatch(_ title: String, total: Int) {
        batchTitle = title; batchCompleted = 0; batchTotal = total; cancellationRequested = false; transferResults = []
    }
    private func endBatch() { batchTitle = nil }

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
        guard canUpload, let capturedAccount = account else { return }
        let ids = uploadQueue.filter { $0.state == .ready }.map(\.id)
        busy = true; beginBatch("Uploading files", total: ids.count)
        defer { busy = false; endBatch() }
        var credentials = capturedAccount
        for id in ids {
            guard !cancellationRequested, accountMatches(capturedAccount),
                  historyAvailable else { break }
            guard let index = uploadQueue.firstIndex(where: { $0.id == id }), let variant = uploadQueue[index].variant,
                  let hash = uploadQueue[index].coreSHA256 else { continue }
            let scope = uploadScope(account: capturedAccount)
            let uncertaintyKey = scope + ":" + hash
            uploadQueue[index].lastAttemptScope = scope
            if uncertainUploadHashes.contains(uncertaintyKey) {
                uploadQueue[index].state = .uncertain
                uploadQueue[index].detail = "An earlier upload may have succeeded. Refresh Shared Files before trying again."
                batchCompleted += 1; continue
            }
            if let pending = sharedUploadIntents?.pending(accountXUID: capturedAccount.xuid, accountEntityID: capturedAccount.entityId, coreSHA256: hash, kind: variant.kind) {
                uploadQueue[index].state = .uncertain
                uploadQueue[index].detail = "An earlier upload needs checking (upload ID \(pending.fileID)). Refresh Shared Files or choose Review."
                batchCompleted += 1; continue
            }
            if history?.receipt(accountXUID: capturedAccount.xuid, coreSHA256: hash) != nil {
                uploadQueue[index].state = .skipped
                uploadQueue[index].detail = "Already uploaded to this account’s Shared Files"
                uploadQueue[index].completedAccountXUID = capturedAccount.xuid
                batchCompleted += 1; continue
            }
            uploadQueue[index].state = .working; uploadQueue[index].detail = "Preparing upload…"
            var preparedSharedUpload: PendingSharedUploads.Entry?
            do {
                credentials = try await currentFileShareCredentials(expected: credentials)
                guard accountMatches(capturedAccount) else { break }
                setStatus("uploading", "Uploading \(variant.title)…")
                let config = try await ServiceDiscovery().resolve(account: credentials, saved: services)
                services = config
                let plan = try FreshVariantMetadata.makePlan(variant: variant, account: credentials)
                preparedSharedUpload = try recordSharedUpload(plan: plan, variant: variant, coreSHA256: hash, account: credentials)
                uploadQueue[index].detail = "Uploading to Shared Files…"
                let published = try await PublisherService().upload(plan: plan, credentials: credentials, services: config)
                receipt = published
                uploadQueue[index].state = .succeeded
                uploadQueue[index].completedAccountXUID = credentials.xuid
                uploadQueue[index].detail = "Uploaded to Shared Files"
                do {
                    try history?.record(published, accountXUID: credentials.xuid)
                    if let preparedSharedUpload {
                        do { try clearSharedUpload(preparedSharedUpload) }
                        catch { uploadQueue[index].detail = "Uploaded. Its recovery record still needs cleanup; Refresh checks it without uploading again." }
                    }
                } catch {
                    historyAvailable = false
                    uploadQueue[index].detail = "Uploaded, but its receipt could not be saved. Shared uploads are paused to prevent duplicates."
                    setStatus("published_history_error", uploadQueue[index].detail, failed: true)
                }
            } catch {
                let uncertain = (error as? PublicationUploadError)?.outcome == .uncertain
                uploadQueue[index].state = uncertain ? .uncertain : .failed
                uploadQueue[index].detail = uncertain
                    ? "Upload outcome is unconfirmed. Refresh Shared Files before trying again. \(error.localizedDescription)"
                    : error.localizedDescription
                if uncertain { uncertainUploadHashes.insert(uncertaintyKey) }
                else if let preparedSharedUpload {
                    do { try clearSharedUpload(preparedSharedUpload) }
                    catch {
                        uploadQueue[index].state = .uncertain
                        uploadQueue[index].detail = "No successful upload was reported, but its recovery record could not be cleared. Refresh Shared Files or choose Review before retrying."
                        uncertainUploadHashes.insert(uncertaintyKey)
                    }
                }
            }
            batchCompleted += 1
        }
        let attempted = Set(ids)
        let count = uploadQueue.filter { attempted.contains($0.id) && $0.state == .succeeded && $0.completedAccountXUID == capturedAccount.xuid }.count
        if historyAvailable {
            setStatus("uploads_finished", cancellationRequested ? "Stopped after the current file. Remaining files are ready." : "Upload queue finished. \(count) file\(count == 1 ? "" : "s") uploaded.")
        }
        if accountMatches(capturedAccount) { await loadFileShare(for: credentials) }
    }
    func refreshFileShare() async {
        guard !operationInProgress, let account else { return }
        await loadFileShare(for: account, isExplicitRefresh: true)
    }
    func downloadSelectedFileShareItem() async {
        let capturedItems = selectedFileShareItems
        guard !operationInProgress, let capturedAccount = account, !capturedItems.isEmpty else { return }
        fileShareBusy = true
        defer { fileShareBusy = false; endBatch() }
        let destination: URL
        if capturedItems.count == 1, let item = capturedItems.first {
            let panel = NSSavePanel()
            panel.title = "Download \(item.kind.label)"; panel.prompt = "Download"
            panel.allowedContentTypes = [UTType(filenameExtension: item.kind.fileExtension) ?? .data]
            panel.allowsOtherFileTypes = false; panel.canCreateDirectories = true; panel.isExtensionHidden = false
            panel.nameFieldStringValue = item.suggestedFilename
            guard panel.runModal() == .OK, let url = panel.url else { return }
            destination = url
        } else {
            let panel = NSOpenPanel()
            panel.title = "Choose a downloads folder"; panel.prompt = "Choose Folder"
            panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.canCreateDirectories = true
            guard panel.runModal() == .OK, let folder = panel.url else { return }
            do { destination = try makeBatchDirectory(in: folder) }
            catch { fileShareError = true; fileShareMessage = error.localizedDescription; return }
        }
        beginBatch("Downloading files", total: capturedItems.count)
        fileShareSavedURL = nil; fileShareSavedTitle = nil; fileShareSavedSHA256 = nil; fileShareError = false
        var credentials = capturedAccount
        for item in capturedItems {
            guard !cancellationRequested, accountMatches(capturedAccount) else { break }
            fileShareMessage = "Downloading \(item.title)…"
            do {
                credentials = try await currentFileShareCredentials(expected: credentials)
                let config = try await ServiceDiscovery().resolve(account: credentials, saved: services)
                services = config
                let download = try await FileShareService().download(item: item, credentials: credentials, services: config)
                guard accountMatches(capturedAccount) else { break }
                let url = capturedItems.count == 1 ? destination : destination.appendingPathComponent(item.suggestedFilename)
                try await Task.detached(priority: .userInitiated) { try download.save(to: url) }.value
                transferResults.append(.init(title: item.title, state: .succeeded, detail: "Saved \(url.lastPathComponent)"))
                fileShareSavedURL = capturedItems.count == 1 ? url : destination
                fileShareSavedTitle = capturedItems.count == 1 ? item.title : "Downloaded files"
                fileShareSavedSHA256 = capturedItems.count == 1 ? download.sha256 : nil
            } catch {
                transferResults.append(.init(title: item.title, state: .failed, detail: error.localizedDescription))
                fileShareError = true
            }
            batchCompleted += 1
        }
        let count = transferResults.filter { $0.state == .succeeded }.count
        fileShareMessage = "Saved \(count) of \(capturedItems.count) files. \(cancellationRequested ? "Stopped after the current file." : "")"
    }
    private func makeBatchDirectory(in parent: URL) throws -> URL {
        let formatter = DateFormatter(); formatter.dateFormat = "yyyy-MM-dd HH.mm.ss"
        let name = "MCC Downloads " + formatter.string(from: Date())
        for suffix in 0..<1000 {
            let url = parent.appendingPathComponent(name + (suffix == 0 ? "" : " (\(suffix + 1))"), isDirectory: true)
            do { try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false); return url }
            catch let error as NSError where error.code == NSFileWriteFileExistsError { continue }
        }
        throw PublisherError.service("A new downloads folder could not be created.")
    }
    func revealDownloadedFile() {
        guard let url = fileShareSavedURL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }
    func deleteSelectedFileShareItem() async {
        let capturedItems = selectedFileShareItems
        guard !operationInProgress, let capturedAccount = account, !capturedItems.isEmpty,
              fileShareDeletionJournalAvailable, deletionIntents != nil else { return }
        guard capturedItems.allSatisfy({ $0.accountXUID == capturedAccount.xuid && $0.accountEntityID == capturedAccount.entityId }) else { return }
        fileShareBusy = true
        defer { fileShareBusy = false; endBatch() }
        guard confirmDeletion(capturedItems) else { return }
        beginBatch("Deleting files", total: capturedItems.count)
        deletionStatusBase = nil; deletionStatusIsWarning = false; deletionRefreshWarning = nil
        updateDeletionStatus(); fileShareError = false
        var credentials = capturedAccount
        do {
            credentials = try await currentFileShareCredentials(expected: credentials)
            let config = try await ServiceDiscovery().resolve(account: credentials, saved: services)
            services = config
            for item in capturedItems {
                guard !cancellationRequested, accountMatches(capturedAccount) else { break }
                credentials = try await currentFileShareCredentials(expected: credentials)
                fileShareMessage = "Deleting \(item.title)…"
                await deleteOne(item, account: credentials, config: config)
                batchCompleted += 1
            }
            retryPendingDeletionHistoryCleanup(for: credentials, retryUnavailableHistory: false)
            await loadFileShare(for: credentials, holdingBusy: true)
            let deleted = transferResults.filter { $0.state == .succeeded }.count
            fileShareMessage = "Deleted \(deleted) of \(capturedItems.count) files. \(cancellationRequested ? "Stopped after the current file." : "")"
        } catch { fileShareError = true; fileShareMessage = error.localizedDescription }
    }
    private func confirmDeletion(_ items: [FileShareItem]) -> Bool {
        let alert = NSAlert(); alert.alertStyle = .warning
        alert.messageText = "Delete \(items.count == 1 ? "this file" : "these \(items.count) files") from Shared Files?"
        alert.informativeText = "These shared copies will be removed from your MCC File Share. Local downloads are kept. This cannot be undone in the app."
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 440, height: min(220, max(90, items.count * 58))))
        scroll.hasVerticalScroller = true; scroll.borderType = .bezelBorder
        let text = NSTextView(frame: scroll.bounds)
        text.isEditable = false; text.isSelectable = true; text.font = .systemFont(ofSize: 11)
        text.string = items.map { "\($0.title) · \($0.kind.label) · \($0.game ?? "MCC")\n\($0.id)" }.joined(separator: "\n\n")
        text.textContainerInset = NSSize(width: 8, height: 8); text.isVerticallyResizable = true
        scroll.documentView = text; alert.accessoryView = scroll
        alert.addButton(withTitle: "Cancel").keyEquivalent = "\r"
        let delete = alert.addButton(withTitle: items.count == 1 ? "Delete File" : "Delete \(items.count) Files")
        delete.hasDestructiveAction = true; delete.keyEquivalent = ""
        return alert.runModal() == .alertSecondButtonReturn
    }

    private func deleteOne(_ item: FileShareItem, account credentials: SignedInAccount, config: MCCServiceConfiguration) async {
        let wasPending = pendingUncertainDeletions[item.id] != nil
        var recordedIntent = false
        do {
            let service = FileShareDeletionService()
            let result: FileShareDeletionResult
            if wasPending {
                // A previous mutation may have succeeded. This batch only rechecks it.
                result = try await service.reconcile(item: item, credentials: credentials, services: config)
            } else {
                try recordDeletionIntent(item); recordedIntent = true
                result = try await service.delete(item: item, credentials: credentials, services: config)
            }
            guard accountMatches(credentials), result.itemID == item.id, result.accountXUID == credentials.xuid,
                  result.accountEntityID == credentials.entityId else {
                pendingUncertainDeletions[item.id] = item
                uncertainDeletionWarnings[item.id] = "“\(item.title)”: deletion result could not be matched. Refresh checks again without deleting again."
                transferResults.append(.init(title: item.title, state: .uncertain, detail: "Deletion result could not be matched; receipt kept."))
                updateDeletionStatus(); return
            }
            if result.confirmedAbsent {
                applyConfirmedDeletion(result, item: item, account: credentials)
                transferResults.append(.init(title: item.title, state: .succeeded, detail: result.message))
            } else if result.outcome == .uncertain || wasPending {
                pendingUncertainDeletions[item.id] = item
                uncertainDeletionWarnings[item.id] = "“\(item.title)”: \(result.message) Refresh checks again without deleting again."
                transferResults.append(.init(title: item.title, state: .uncertain, detail: result.message))
            } else {
                clearConcludedDeletionIntent(item, reason: "MCC refused deletion")
                transferResults.append(.init(title: item.title, state: .failed, detail: result.message))
            }
        } catch {
            if recordedIntent && !wasPending { clearConcludedDeletionIntent(item, reason: "No deletion request was sent") }
            transferResults.append(.init(title: item.title, state: wasPending ? .uncertain : .failed, detail: error.localizedDescription))
            if wasPending { uncertainDeletionWarnings[item.id] = "“\(item.title)”: deletion remains unconfirmed. Refresh checks again without deleting again." }
        }
        updateDeletionStatus()
    }
    private func loadFileShare(for requestAccount: SignedInAccount, holdingBusy: Bool = false, isExplicitRefresh: Bool = false) async {
        guard !fileShareBusy || holdingBusy else { return }
        fileShareBusy = true; fileShareLoading = true; fileShareError = false
        fileShareMessage = "Loading Shared Files…"
        defer { if !holdingBusy { fileShareBusy = false }; fileShareLoading = false }
        if isExplicitRefresh {
            reloadPublicationHistoryIfNeeded()
            loadDeletionJournalIfNeeded()
            loadSharedUploadJournalIfNeeded()
        }
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
            guard accountMatches(requestAccount) else { return }
            reconcileSharedUploads(in: listing.items, account: credentials)
            // MCC may briefly return a stale catalog entry after confirming removal.
            // A confirmed-deleted ID stays unavailable for this account in this session.
            fileShareItems = listing.items.filter { confirmedAbsentItems[$0.id] == nil }
            let suppressed = listing.items.count - fileShareItems.count
            deletionRefreshWarning = suppressed == 0 ? nil : "MCC still listed \(suppressed) confirmed-deleted item\(suppressed == 1 ? "" : "s"). Those entries are hidden from this browser."
            updateDeletionStatus()
            fileShareHasLoaded = true
            fileShareWarning = listing.isComplete ? nil : (listing.warning ?? "Only part of your File Share could be loaded. Refresh to try again.")
            trimSelection()
            let count = fileShareItems.count
            if listing.isComplete {
                fileShareMessage = count == 0 ? "No maps or gametypes are on this account’s Shared Files." : "\(count) file\(count == 1 ? "" : "s") on your File Share."
            } else {
                fileShareMessage = "\(count) file\(count == 1 ? "" : "s") loaded. Results are incomplete."
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
            if sharedUploadJournalAvailable { sharedUploadJournalMessage = nil }
            confirmedAbsentItems.removeAll(); pendingDeletionHistoryCleanup.removeAll()
            pendingUncertainDeletions.removeAll(); uncertainDeletionWarnings.removeAll()
            deletionStatusBase = nil; deletionStatusIsWarning = false
            deletionHistoryWarning = nil; deletionRefreshWarning = nil
            fileShareDeletionMessage = nil; fileShareDeletionHasWarning = false
        }
        fileShareAccountScope = nextScope
        restoreJournaledDeletionIntents()
        fileShareItems = []; fileShareSelection = []; transferResults = []
        fileShareHasLoaded = false; fileShareError = false; fileShareWarning = nil; fileShareNeedsSignIn = false
        fileShareSavedURL = nil; fileShareSavedTitle = nil; fileShareSavedSHA256 = nil
        fileShareMessage = account == nil ? "Sign in to browse your MCC File Share." : "Your File Share is ready to load."
    }
    private func accountMatches(_ expected: SignedInAccount) -> Bool {
        account?.xuid == expected.xuid && account?.entityId == expected.entityId
    }
    private func loadSharedUploadJournalIfNeeded() {
        guard sharedUploadIntents == nil else { return }
        do {
            sharedUploadIntents = try PendingSharedUploads(url: statusURL.deletingLastPathComponent().appendingPathComponent("shared-upload-intents.json"))
            sharedUploadJournalAvailable = true; sharedUploadJournalMessage = nil
            rebindUploadQueue()
        } catch {
            sharedUploadJournalAvailable = false
            sharedUploadJournalMessage = "Shared uploads are paused because upload recovery records could not be read. Refresh retries loading them. \(error.localizedDescription)"
        }
    }
    private func recordSharedUpload(plan: UploadPlan, variant: ReachVariantDocument, coreSHA256: String, account: SignedInAccount) throws -> PendingSharedUploads.Entry {
        guard var journal = sharedUploadIntents, sharedUploadJournalAvailable else { throw PublisherError.service("Shared upload recovery records are unavailable. Refresh before uploading.") }
        let entry = try journal.record(accountXUID: account.xuid, accountEntityID: account.entityId, coreSHA256: coreSHA256,
            kind: variant.kind, fileID: plan.fileID, title: variant.title)
        sharedUploadIntents = journal
        return entry
    }
    private func clearSharedUpload(_ entry: PendingSharedUploads.Entry) throws {
        guard var journal = sharedUploadIntents else { throw PublisherError.service("Shared upload recovery records are unavailable.") }
        try journal.remove(entry); sharedUploadIntents = journal
    }
    /// Reload only when no history instance exists. An existing instance may
    /// retain acknowledged receipts that failed to reach disk and must not be lost.
    func reloadPublicationHistoryIfNeeded() {
        guard history == nil else { return }
        do {
            history = try PublicationHistory(url: statusURL.deletingLastPathComponent().appendingPathComponent("publications.json"))
            historyAvailable = true
        } catch { historyAvailable = false }
    }
    func reconcileSharedUploads(in items: [FileShareItem], account expected: SignedInAccount) {
        guard accountMatches(expected), let journal = sharedUploadIntents else { return }
        var warnings: [String] = []
        for pending in journal.pending(accountXUID: expected.xuid, accountEntityID: expected.entityId) {
            let matches = items.filter { pending.matches($0) }
            guard matches.count == 1, let found = matches.first else {
                warnings.append("“\(pending.title)” still needs checking. Refresh or review the pending upload; no automatic retry was made.")
                continue
            }
            guard history != nil else {
                historyAvailable = false
                warnings.append("“\(pending.title)” was found in Shared Files, but publication receipts are unavailable. Duplicate protection remains active.")
                continue
            }
            let recovered = PublicationReceipt(itemID: found.id, title: found.title, publishedAt: found.modifiedAt ?? Date(), downloadVerified: false, fileSHA256: pending.coreSHA256)
            do {
                try history?.record(recovered, accountXUID: expected.xuid)
                // record persists every in-memory receipt, including any retained
                // after a prior write failure. Only that success restores uploads.
                historyAvailable = true
            } catch {
                historyAvailable = false
                warnings.append("“\(pending.title)” was found in Shared Files, but its receipt could not be saved. Shared uploads remain paused and duplicate protection stays active. \(error.localizedDescription)")
                continue
            }
            do { try clearSharedUpload(pending) }
            catch {
                // Receipt persistence already succeeded. A recovery-journal
                // cleanup problem must not mark those durable receipts unavailable.
                warnings.append("“\(pending.title)” has a saved receipt, but its recovery record could not be cleared. Duplicate protection remains active. \(error.localizedDescription)")
                continue
            }
            let scope = uploadScope(account: expected)
            uncertainUploadHashes.remove(scope + ":" + pending.coreSHA256)
            for index in uploadQueue.indices where uploadQueue[index].coreSHA256 == pending.coreSHA256 && uploadQueue[index].variant?.kind == pending.kind {
                uploadQueue[index].state = .succeeded
                uploadQueue[index].lastAttemptScope = scope
                uploadQueue[index].completedAccountXUID = expected.xuid
                uploadQueue[index].detail = "Upload found in Shared Files. Its receipt was recovered."
            }
        }
        if sharedUploadJournalAvailable { sharedUploadJournalMessage = warnings.isEmpty ? nil : warnings.joined(separator: " ") }
    }
    func canReviewUpload(_ entry: UploadQueueEntry) -> Bool {
        guard entry.state == .uncertain, let account, let hash = entry.coreSHA256, let variant = entry.variant else { return false }
        return sharedUploadIntents?.pending(accountXUID: account.xuid, accountEntityID: account.entityId, coreSHA256: hash, kind: variant.kind) != nil
    }
    func reviewPendingUpload(_ id: UUID) {
        guard !libraryInteractionDisabled, let account,
              let index = uploadQueue.firstIndex(where: { $0.id == id }), uploadQueue[index].state == .uncertain, let hash = uploadQueue[index].coreSHA256,
              let variant = uploadQueue[index].variant,
              let pending = sharedUploadIntents?.pending(accountXUID: account.xuid, accountEntityID: account.entityId, coreSHA256: hash, kind: variant.kind) else { return }
        let alert = NSAlert(); alert.alertStyle = .warning
        alert.messageText = "Review “\(pending.title)” before retrying"
        alert.informativeText = "An earlier upload may already be in Shared Files. Check that library before allowing a new upload, which could create a duplicate.\n\nType: \(pending.kind.label)\nUpload ID: \(pending.fileID)\nPrepared: \(pending.createdAt.formatted(date: .abbreviated, time: .shortened))\n\nAllowing a new upload only makes this queue entry ready; it does not upload it."
        alert.addButton(withTitle: "Cancel").keyEquivalent = "\r"
        alert.addButton(withTitle: "Find in Shared Files")
        alert.addButton(withTitle: "Allow a new upload").keyEquivalent = ""
        switch alert.runModal() {
        case .alertSecondButtonReturn:
            showUploads = false; searchText = pending.title
        case .alertThirdButtonReturn:
            do {
                try clearSharedUpload(pending)
                uncertainUploadHashes.remove(uploadScope(account: account) + ":" + hash)
                uploadQueue[index].state = .ready
                uploadQueue[index].detail = "A new upload was explicitly allowed after review."
                sharedUploadJournalMessage = nil
            } catch { uploadQueue[index].detail = "The recovery record could not be cleared. No new upload was allowed. \(error.localizedDescription)" }
        default: break
        }
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
            uncertainDeletionWarnings[item.id] = "A saved deletion intent for “\(item.title)” needs checking. It does not prove the file was deleted. Refresh checks this item without sending another deletion request."
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
        fileShareSelection.remove(result.itemID)
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
    private func uploadScope(account: SignedInAccount?) -> String {
        (account?.xuid ?? "signed-out") + ":" + (account?.entityId ?? "no-entity")
    }
    private func rebindUploadQueue() {
        let scope = uploadScope(account: account)
        for index in uploadQueue.indices where uploadQueue[index].variant != nil {
            if let previous = uploadQueue[index].lastAttemptScope, previous != scope {
                uploadQueue[index].state = .ready
                uploadQueue[index].detail = "Ready to upload to Shared Files"
                uploadQueue[index].completedAccountXUID = nil
            }
            if let account, let hash = uploadQueue[index].coreSHA256, let variant = uploadQueue[index].variant,
               sharedUploadIntents?.pending(accountXUID: account.xuid, accountEntityID: account.entityId, coreSHA256: hash, kind: variant.kind) != nil {
                uploadQueue[index].state = .uncertain
                uploadQueue[index].lastAttemptScope = scope
                uploadQueue[index].detail = "An earlier upload needs checking. Refresh Shared Files or choose Review before retrying."
            }
            if let hash = uploadQueue[index].coreSHA256, uncertainUploadHashes.contains(scope + ":" + hash) {
                uploadQueue[index].state = .uncertain
                uploadQueue[index].detail = "An earlier upload may have succeeded. Refresh Shared Files before trying again."
            }
        }
    }
    private func restoreMatchingReceipt() {
        receipt = nil
        rebindUploadQueue()
        if !historyAvailable {
            setStatus("history_unavailable", "Publication history could not be read. Uploads are paused to prevent duplicate entries.", failed: true)
        } else {
            setStatus(account == nil ? "signed_out" : "signed_in", account == nil ? "Sign in to manage your MCC files." : "Connected. Add Reach maps or gametypes to upload.")
        }
    }
    private func fail(_ value: Error) { setStatus("error", value.localizedDescription, failed: true) }
    private func setStatus(_ stage: String, _ text: String, failed: Bool = false) {
        message = text; error = failed
        let snapshot = JSONValue.object([
            "stage": .string(stage), "message": .string(text), "signedIn": .bool(account != nil),
            "filesQueued": .bool(!uploadQueue.isEmpty), "published": .bool(receipt != nil),
            "downloadVerified": .bool(receipt?.downloadVerified ?? false), "updatedAt": .string(ISO8601DateFormatter().string(from: Date()))
        ])
        if let data = try? snapshot.encoded() { try? data.write(to: statusURL, options: .atomic); try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: statusURL.path) }
    }
}
