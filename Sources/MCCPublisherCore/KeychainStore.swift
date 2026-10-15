import Foundation
import Security
import CryptoKit

/// Where the app keeps its sign-in. macOS lets a build read keychain items it created without
/// asking, and asks before a build reads an item another build created.
public protocol CredentialVault: Sendable {
    /// Identifies the running build's code signature in the account names of the items it creates.
    var ownerTag: String { get }
    /// Saved accounts starting with `prefix`, newest first. Reads attributes only, so it never asks the user.
    func accounts(withPrefix prefix: String) -> [String]
    func readData(account: String) throws -> Data?
    func setData(_ data: Data, account: String) throws
    /// Deletes the item. Only the build that created an item may delete it, so another build's
    /// item has its secret overwritten instead.
    func delete(account: String) throws
}

public struct KeychainStore: CredentialVault {
    public let service: String
    public init(service: String = Bundle.main.bundleIdentifier ?? "org.mjolnir.MCCForgePublisher") { self.service = service }
    public var ownerTag: String { Self.ownerTag }
    public func accounts(withPrefix prefix: String) -> [String] {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                kSecReturnAttributes as String: true, kSecMatchLimit as String: kSecMatchLimitAll]
        var items: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &items) == errSecSuccess, let found = items as? [[String: Any]] else { return [] }
        return found.compactMap { item -> (account: String, created: Date, modified: Date)? in
            guard let account = item[kSecAttrAccount as String] as? String, account.hasPrefix(prefix) else { return nil }
            return (account, item[kSecAttrCreationDate as String] as? Date ?? .distantPast,
                    item[kSecAttrModificationDate as String] as? Date ?? .distantPast)
        }.sorted { ($0.created, $0.modified) > ($1.created, $1.modified) }.map(\.account)
    }
    public func readData(account: String) throws -> Data? {
        let q = query(account).merging([kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]) { _, b in b }
        var item: CFTypeRef?; let status = SecItemCopyMatching(q as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw failure(status) }
        return item as? Data
    }
    public func setData(_ data: Data, account: String) throws {
        let attributes: [String: Any] = [kSecValueData as String: data, kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        let update = SecItemUpdate(query(account) as CFDictionary, attributes as CFDictionary)
        if update == errSecItemNotFound {
            let add = SecItemAdd(query(account).merging(attributes) { _, b in b }
                .merging([kSecAttrLabel as String: "MCC Forge Publisher sign-in"]) { _, b in b } as CFDictionary, nil)
            guard add == errSecSuccess else { throw failure(add) }
        } else if update != errSecSuccess { throw failure(update) }
    }
    public func delete(account: String) throws {
        let s = SecItemDelete(query(account) as CFDictionary)
        if s == errSecSuccess || s == errSecItemNotFound { return }
        guard s == errSecInvalidOwnerEdit else { throw failure(s) }
        // Any build may overwrite an item's data without asking; "{}" decodes as an empty sign-in.
        let cleared = SecItemUpdate(query(account) as CFDictionary, [kSecValueData as String: Data("{}".utf8)] as CFDictionary)
        guard cleared == errSecSuccess || cleared == errSecItemNotFound else { throw failure(cleared) }
    }
    private func query(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
    }
    private func failure(_ status: OSStatus) -> PublisherError {
        .authentication("macOS Keychain could not store or read this app's sign-in (status \(status)).")
    }

    /// A short hash of the running code's designated requirement. An ad-hoc signature changes with
    /// every build; a signing certificate keeps it the same across builds.
    private static let ownerTag: String = {
        var code: SecCode?, staticCode: SecStaticCode?, requirement: SecRequirement?, text: CFString?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code,
              SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode,
              SecCodeCopyDesignatedRequirement(staticCode, [], &requirement) == errSecSuccess, let requirement,
              SecRequirementCopyString(requirement, [], &text) == errSecSuccess, let text else { return "unsigned" }
        return SHA256.hash(data: Data((text as String).utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
    }()
}
