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
    private let auth = AuthService()
    private let loginWindow = MicrosoftLoginWindow()
    private var restored = false
    private var services: MCCServiceConfiguration?
    private let statusURL: URL
    private var history: PublicationHistory?
    private var selectedCoreSHA256: String?

    init() {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!.appendingPathComponent("MCCForgePublisher")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path)
        statusURL = dir.appendingPathComponent("status.json")
        do { history = try PublicationHistory(url: dir.appendingPathComponent("publications.json")) }
        catch { historyAvailable = false; setStatus("history_unavailable", "Publication history could not be read. Upload is paused to avoid duplicate entries.", failed: true) }
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
            restoreMatchingReceipt()
        } catch AuthError.signInRequired {
            setStatus("sign_in_required", "Sign in again to reconnect your MCC account.")
        } catch {
            // Keep the reason: a refusal that also stops a fresh sign-in needs more than signing in again.
            setStatus("sign_in_required", "Sign in again to reconnect your MCC account. Reconnecting failed: \(error.localizedDescription)")
        }
    }
    func signIn() async {
        guard !busy else { return }; busy = true; defer { busy = false }
        do {
            setStatus("signing_in", "Opening Microsoft sign-in…")
            let challenge = try await auth.beginSignIn()
            let callback = try await loginWindow.authorize(challenge)
            setStatus("connecting", "Connecting your Xbox profile to MCC…")
            account = try await auth.completeSignIn(callback: callback)
            restoreMatchingReceipt()
        } catch { fail(error) }
    }
    func signOut() async {
        guard !busy else { return }
        do { try await auth.signOut(); account = nil; receipt = nil; setStatus("signed_out", "Signed out.") } catch { fail(error) }
    }
    func chooseMap() {
        let panel = NSOpenPanel(); panel.allowedContentTypes = [UTType(filenameExtension: "mvar") ?? .data]
        panel.canChooseDirectories = false; panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url { select(url) }
    }
    func select(_ url: URL) {
        guard !busy else { return }
        do {
            let selected = try ReachMapDocument.load(from: url)
            map = selected
            selectedCoreSHA256 = SHA256.hash(data: Data(selected.bytes.prefix(selected.embeddedLength)))
                .map { String(format: "%02x", $0) }.joined()
            restoreMatchingReceipt()
        } catch { fail(error) }
    }
    func chooseConfiguration() {
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.json]; panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            do {
                let data = try Data(contentsOf: url); let value = try JSONDecoder().decode(JSONValue.self, from: data)
                let config: MCCServiceConfiguration
                if value["upload"].string != nil {
                    let saved = try JSONDecoder().decode(MCCServiceConfiguration.self, from: data)
                    config = try MCCServiceConfiguration(upload: saved.upload, permission: saved.permission, itemLookup: saved.itemLookup, sandbox: saved.sandbox, source: saved.source)
                } else { config = try MCCServiceConfiguration.discovered(from: value, source: url.lastPathComponent) }
                services = config
                let out = statusURL.deletingLastPathComponent().appendingPathComponent("services.json")
                try JSONEncoder().encode(config).write(to: out, options: .atomic)
                setStatus("configured", "MCC service configuration loaded.")
            } catch { fail(error) }
        }
    }
    func publish() async {
        guard !busy, historyAvailable, let map, let account else { return }
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
        guard !busy, let receipt, let account else { return }
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
