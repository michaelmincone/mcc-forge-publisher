import Foundation

/// An acknowledged HTTP request is not by itself evidence that an item is gone.
public struct FileShareDeletionResult: Sendable, Equatable {
    public enum Outcome: Sendable, Equatable { case deleted, alreadyAbsent, notDeleted, uncertain }
    public let itemID: String
    public let title: String
    public let accountXUID: String
    public let accountEntityID: String
    public let outcome: Outcome
    public let message: String
    public var confirmedAbsent: Bool { outcome == .deleted || outcome == .alreadyAbsent }

    init(itemID: String, title: String, accountXUID: String, accountEntityID: String, outcome: Outcome, message: String) {
        self.itemID = itemID; self.title = title; self.accountXUID = accountXUID
        self.accountEntityID = accountEntityID; self.outcome = outcome; self.message = message
    }
}

public struct FileShareDeletionService: Sendable {
    public let http: HTTPClient
    public init(http: HTTPClient = HTTPClient()) { self.http = http }

    /// Sends at most one mutation. Any failure after dispatch must be reconciled
    /// read-only; callers must never interpret a transport error as safe to retry.
    public func delete(item: FileShareItem, credentials: SignedInAccount, services: MCCServiceConfiguration) async throws -> FileShareDeletionResult {
        try validate(item: item, credentials: credentials, services: services)
        try Task.checkCancellation()
        let fresh: FileShareItem
        do {
            fresh = try await FileShareService(http: http).lookup(itemID: item.id, credentials: credentials, services: services)
        } catch {
            // Auth/identity/type/malformed-data failures cannot be converted into
            // permission to delete. Only a complete own-list can prove that an
            // unavailable selected item was already absent before any mutation.
            try rejectPreflightMismatch(error)
            let state = await observe(itemID: item.id, credentials: credentials, services: services, allowNotFoundProbe: false)
            if state == .absent {
                return result(item, credentials, .alreadyAbsent, "This file was already absent from your File Share. No deletion request was sent.")
            }
            try Task.checkCancellation()
            throw PublisherError.service("The selected file's current ownership and availability could not be verified. No deletion request was sent; refresh the File Share before continuing.")
        }
        guard fresh.id == item.id.lowercased(), fresh.accountXUID == credentials.xuid, fresh.accountEntityID == credentials.entityId, fresh.kind == item.kind else {
            throw PublisherError.protocolError("The selected File Share file changed identity, kind, or ownership. No deletion request was sent; refresh the list.")
        }
        let body = try JSONValue.object(["ItemId": .string(fresh.id)]).encoded()
        try Task.checkCancellation()
        let reply: MutationReply
        // This is the dispatch boundary. There are deliberately no retries,
        // alternate endpoints, or thrown cancellation/network errors afterward.
        do {
            let response = try await http.send(url: services.itemDeletion, method: "POST", headers: [
                "X-EntityToken": credentials.entityToken, "Accept": "application/json", "Content-Type": "application/json",
            ], body: body, allowsRedirects: false)
            reply = Self.mutationReply(response)
        } catch let error as HTTPStatusError {
            // An ordinary 4xx refusal is explicit. Timeouts and server failures
            // can occur after mutation, so they remain ambiguous.
            reply = (400..<500).contains(error.status) && error.status != 408 ? .refused : .ambiguous
        } catch {
            // Do not retain or show URLSession errors/raw service bodies: they
            // may include tokens, URLs, or sensitive request metadata.
            reply = .ambiguous
        }
        let state = await observe(itemID: fresh.id, credentials: credentials, services: services, allowNotFoundProbe: true)
        if state == .absent {
            let outcome: FileShareDeletionResult.Outcome = reply == .refused ? .alreadyAbsent : .deleted
            return result(fresh, credentials, outcome, "The file is no longer on your File Share. Its absence was confirmed.")
        }
        if reply == .refused {
            return result(fresh, credentials, .notDeleted, "MCC refused the deletion request. The file was not confirmed absent; refresh the File Share before trying again.")
        }
        if state == .present {
            return result(fresh, credentials, .uncertain, "Deletion could not be confirmed because the file still appears on your File Share. MCC may still be processing the request; refresh before making another deletion attempt.")
        }
        return result(fresh, credentials, .uncertain, "Deletion could not be confirmed. MCC may have processed the request; refresh your File Share before making another deletion attempt.")
    }

    /// Recheck a previously uncertain item without sending another mutation.
    /// This lets an explicit refresh confirm an eventually-consistent deletion
    /// even after the item disappears from the browser's selectable rows.
    public func reconcile(item: FileShareItem, credentials: SignedInAccount, services: MCCServiceConfiguration) async throws -> FileShareDeletionResult {
        try validate(item: item, credentials: credentials, services: services)
        try Task.checkCancellation()
        let state = await observe(itemID: item.id, credentials: credentials, services: services, allowNotFoundProbe: true)
        if state == .absent {
            return result(item, credentials, .deleted, "The previously requested deletion is now confirmed. The file is no longer on your File Share.")
        }
        return result(item, credentials, .uncertain, state == .present
            ? "The file still appears on your File Share. The previous deletion remains unconfirmed."
            : "The previous deletion could not be confirmed. Refresh your File Share to check again; no new deletion request was sent.")
    }

    private enum MutationReply { case acknowledged, refused, ambiguous }
    private enum Presence { case absent, present, unknown }

    private func validate(item: FileShareItem, credentials: SignedInAccount, services: MCCServiceConfiguration) throws {
        guard credentials.expiresAt > Date(), !credentials.xuid.isEmpty, !credentials.entityId.isEmpty,
              !credentials.entityToken.isEmpty else { throw AuthError.signInRequired }
        guard item.accountXUID == credentials.xuid, item.accountEntityID == credentials.entityId else {
            throw PublisherError.authentication("This file belongs to a different signed-in account. Refresh your File Share; no deletion request was sent.")
        }
        guard UUID(uuidString: item.id) != nil else { throw PublisherError.protocolError("The selected file has an invalid catalog ID. No deletion request was sent.") }
        for value in [credentials.entityToken, credentials.entityId] where value.utf8.contains(10) || value.utf8.contains(13) {
            throw PublisherError.authentication("The signed-in account's credentials are invalid. Sign in again; no deletion request was sent.")
        }
        for url in [services.itemLookup, services.itemListing, services.itemDeletion] { try MCCServiceConfiguration.validate(url) }
    }

    private func rejectPreflightMismatch(_ error: Error) throws {
        if error is CancellationError { throw CancellationError() }
        if let value = error as? AuthError { throw value }
        if let value = error as? PublisherError {
            switch value {
            case .authentication, .protocolError, .invalidMap: throw value
            case .cancelled: throw CancellationError()
            case .service: break
            }
        }
        if let value = error as? HTTPStatusError, [401, 403].contains(value.status) {
            throw PublisherError.authentication("MCC refused the account check. Sign in again; no deletion request was sent.")
        }
    }

    private static func mutationReply(_ response: HTTPResponse) -> MutationReply {
        // Native completion checks transport HRESULT only; no mandatory JSON
        // success schema exists. An empty successful response is a valid ACK.
        if response.data.isEmpty { return .acknowledged }
        guard let root = try? JSONDecoder().decode(JSONValue.self, from: response.data), root.object != nil else { return .ambiguous }
        let body = root["data"].object != nil ? root["data"] : root
        for value in [root, body] {
            if value["Error"] != .null || value["error"] != .null || value["errorCode"] != .null { return .refused }
            if value["code"] != .null && value["code"] != .number(200) { return .refused }
        }
        if root["data"] != .null && root["data"].object == nil { return .ambiguous }
        return .acknowledged
    }

    private func observe(itemID: String, credentials: SignedInAccount, services: MCCServiceConfiguration, allowNotFoundProbe: Bool) async -> Presence {
        do {
            let response = try await http.send(url: services.itemListing, method: "POST", headers: [
                "Accept": "application/json", "CreatorEntityId": credentials.entityId, "UserEntityId": credentials.entityId,
            ], body: Data("{}".utf8))
            let state = Self.presence(in: response.json, itemID: itemID, owner: credentials.entityId)
            // A still-visible list must never be overridden by a contradictory
            // not-found probe; an eventually-consistent result is uncertain.
            if state != .unknown { return state }
        } catch { /* A failed listing is not an empty share. */ }
        guard allowNotFoundProbe else { return .unknown }
        do {
            let response = try await http.send(url: services.itemLookup, method: "POST", headers: [
                "X-EntityToken": credentials.entityToken, "Accept": "application/json", "Content-Type": "application/json",
            ], body: JSONValue.object(["ItemId": .string(itemID)]).encoded())
            if Self.exactItemNotFound(response.json) { return .absent }
        } catch let error as HTTPStatusError where error.code == "ItemNotFound" { return .absent }
        catch { /* Generic 404, missing Item or malformed JSON prove nothing. */ }
        return .unknown
    }

    private static func presence(in root: JSONValue, itemID: String, owner: String) -> Presence {
        guard let body = try? FileShareService.envelope(root), let rows = body["Items"].array else { return .unknown }
        // Inspect every content type. Absence from the file-filtered UI result
        // would not prove absence if the same ID now has another content type.
        if rows.contains(where: { $0["Id"].string?.lowercased() == itemID.lowercased() && $0["CreatorEntity"]["Id"].string == owner }) { return .present }
        guard let count = body["Count"].number, count.isFinite, count >= 0, count.rounded() == count,
              count == Double(rows.count), !hasContinuation(root), !hasContinuation(body) else { return .unknown }
        var ids: Set<String> = []
        for row in rows {
            guard row.object != nil, let id = row["Id"].string, UUID(uuidString: id) != nil,
                  let type = row["ContentType"].string, !type.isEmpty,
                  row["CreatorEntity"]["Id"].string == owner, ids.insert(id.lowercased()).inserted else { return .unknown }
        }
        return .absent
    }

    private static func hasContinuation(_ value: JSONValue) -> Bool {
        for key in ["ContinuationToken", "continuationToken", "NextToken", "nextToken", "Continuation", "continuation", "NextLink", "nextLink"] {
            if value[key] != .null && value[key] != .string("") { return true }
        }
        for key in ["HasMore", "hasMore", "HasMoreResults", "hasMoreResults"] {
            if value[key] != .null && value[key] != .bool(false) { return true }
        }
        return false
    }

    private static func exactItemNotFound(_ root: JSONValue) -> Bool {
        guard root.object != nil else { return false }
        let body = root["data"].object != nil ? root["data"] : root
        guard root["Item"] == .null, body["Item"] == .null else { return false }
        for envelope in [root, body] {
            for key in ["error", "errorCode", "Error", "ErrorCode"] where envelope[key].string == "ItemNotFound" { return true }
            for error in [envelope["Error"], envelope["error"]] where error.object != nil {
                for key in ["Error", "error", "ErrorCode", "errorCode", "Code", "code"] where error[key].string == "ItemNotFound" { return true }
            }
        }
        return false
    }

    private func result(_ item: FileShareItem, _ credentials: SignedInAccount, _ outcome: FileShareDeletionResult.Outcome, _ message: String) -> FileShareDeletionResult {
        FileShareDeletionResult(itemID: item.id, title: item.title, accountXUID: credentials.xuid, accountEntityID: credentials.entityId, outcome: outcome, message: message)
    }
}
