import Foundation
import CryptoKit
import CZlib
import Darwin

/// Catalog identity is independent of both its title and its UUID-like filename.
public struct FileShareItem: Identifiable, Sendable, Equatable {
    public let id: String
    public let title: String
    public let description: String
    public let game: String?
    public let baseMap: String?
    public let fileSize: Int?
    public let modifiedAt: Date?
    public let accountEntityID: String
    public let accountXUID: String
    public let gameEngine: String?
    public let baseMapID: String?
    public var suggestedFilename: String { Self.filename(title: title, id: id) }

    /// Reconstruct catalog identity for display or a read-only state check.
    /// A snapshot is never evidence of current ownership or deletion success;
    /// mutating services must validate fresh remote metadata independently.
    public init(id: String, title: String, description: String = "", game: String? = nil, baseMap: String? = nil,
                fileSize: Int? = nil, modifiedAt: Date? = nil, accountEntityID: String, accountXUID: String,
                gameEngine: String? = nil, baseMapID: String? = nil) {
        self.id = id; self.title = title; self.description = description; self.game = game; self.baseMap = baseMap
        self.fileSize = fileSize; self.modifiedAt = modifiedAt; self.accountEntityID = accountEntityID
        self.accountXUID = accountXUID; self.gameEngine = gameEngine; self.baseMapID = baseMapID
    }

    static func filename(title: String, id: String) -> String {
        let forbidden = CharacterSet.controlCharacters.union(CharacterSet(charactersIn: "/\\:"))
        var name = title.unicodeScalars.map { forbidden.contains($0) ? "_" : String($0) }.joined()
        name = name.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: ".")))
        if name.lowercased().hasSuffix(".mvar") { name.removeLast(5) }
        if name.isEmpty { name = "Map Variant" }
        // Leave room for a stable suffix, extension and the filesystem's byte limit.
        while name.utf8.count > 160 { name.removeLast() }
        let suffix = id.filter { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }.prefix(36)
        return name + (suffix.isEmpty ? "" : " - " + suffix) + ".mvar"
    }
}

public struct FileShareListing: Sendable, Equatable {
    public let items: [FileShareItem]
    public let isComplete: Bool
    public let warning: String?
    /// Includes all content types, before the map-only browser filter.
    public let catalogItemCount: Int
}

/// Validated BLF bytes. SHA-256 establishes saved/downloaded byte identity;
/// game-specific load compatibility and catalog signature trust are separate.
public struct FileShareDownload: Sendable {
    public let data: Data
    public let sha256: String
    public let itemID: String

    init(data: Data, itemID: String) throws {
        try MapVariantDownloadValidator.validate(data)
        self.data = data
        self.sha256 = Self.hash(data)
        self.itemID = itemID
    }

    /// Stage, verify and sync in the destination directory, then atomically rename.
    /// A failed stage cannot truncate an existing destination or leave a .mvar.
    public func save(to destination: URL) throws {
        guard destination.isFileURL, destination.pathExtension.lowercased() == "mvar" else {
            throw PublisherError.service("Choose a local destination with the .mvar extension.")
        }
        let manager = FileManager.default
        let stage = destination.deletingLastPathComponent().appendingPathComponent(".mcc-download-\(UUID().uuidString).tmp")
        defer { try? manager.removeItem(at: stage) }
        try Task.checkCancellation()
        try data.write(to: stage, options: .withoutOverwriting)
        let handle = try FileHandle(forWritingTo: stage)
        do { try handle.synchronize(); try handle.close() }
        catch { try? handle.close(); throw error }
        let staged = try Data(contentsOf: stage)
        guard staged.count == data.count, Self.hash(staged) == sha256 else {
            throw PublisherError.service("The staged map failed its byte-integrity check; no map was saved.")
        }
        try Task.checkCancellation()
        let result = stage.withUnsafeFileSystemRepresentation { source in
            destination.withUnsafeFileSystemRepresentation { target in
                Darwin.rename(source!, target!)
            }
        }
        guard result == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno), userInfo: [NSFilePathErrorKey: destination.path])
        }
    }

    private static func hash(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
}

public struct FileShareService: Sendable {
    public let http: HTTPClient
    public init(http: HTTPClient = HTTPClient()) { self.http = http }

    public func list(credentials: SignedInAccount, services: MCCServiceConfiguration) async throws -> FileShareListing {
        try Self.validate(credentials)
        try MCCServiceConfiguration.validate(services.itemListing)
        // The recovered MCC request filters by CreatorEntityId and scopes the
        // requesting account with UserEntityId. It uses an empty JSON body.
        let response = try await request(url: services.itemListing, method: "POST", headers: [
            "Accept": "application/json", "CreatorEntityId": credentials.entityId, "UserEntityId": credentials.entityId,
        ], body: Data("{}".utf8))
        let body = try Self.envelope(response.json)
        guard let rows = body["Items"].array else {
            throw PublisherError.protocolError("MCC returned no recognizable File Share item list. Refresh or sign in again.")
        }
        var warnings: [String] = []
        let count = Self.nonnegativeInteger(body["Count"])
        if count == nil { warnings.append("MCC did not provide a valid total count, so this list cannot be confirmed complete.") }
        else if count != rows.count { warnings.append("MCC returned \(rows.count) catalog entries but reported \(count!) entries; this list is incomplete.") }
        // No continuation request contract is established for the MCC wrapper.
        // Never invent PlayFab SearchItems pagination headers or hide this state.
        if Self.hasContinuation(body) || Self.hasContinuation(response.json) {
            warnings.append("MCC returned a continuation that this service version cannot follow. The entries shown are only a partial list.")
        }
        var items: [FileShareItem] = []
        var seen: [String: JSONValue] = [:]
        for row in rows {
            guard row.object != nil, let id = Self.itemID(row), let type = row["ContentType"].string, !type.isEmpty else {
                warnings.append("MCC returned an invalid catalog entry; some maps may be missing."); continue
            }
            if let prior = seen[id] {
                if prior != row { warnings.append("MCC returned conflicting entries for the same catalog ID; refresh the list.") }
                continue
            }
            seen[id] = row
            guard row["CreatorEntity"]["Id"].string == credentials.entityId else {
                warnings.append("MCC returned an entry whose ownership could not be confirmed for this account; it was omitted."); continue
            }
            guard type == "MapVariant" else { continue }
            items.append(Self.item(row, credentials: credentials))
        }
        if seen.count != rows.count { warnings.append("The response included duplicate or malformed catalog entries, so completeness could not be confirmed.") }
        let uniqueWarnings = Array(NSOrderedSet(array: warnings)) as? [String] ?? warnings
        return FileShareListing(items: items, isComplete: warnings.isEmpty,
                                warning: uniqueWarnings.isEmpty ? nil : uniqueWarnings.joined(separator: " "), catalogItemCount: rows.count)
    }

    /// Retrieve current metadata without relying on a publication receipt or an
    /// old signed URL. Catalog ownership must still match the selected account.
    public func lookup(itemID: String, credentials: SignedInAccount, services: MCCServiceConfiguration) async throws -> FileShareItem {
        let raw = try await details(itemID: itemID, credentials: credentials, services: services)
        return Self.item(raw, credentials: credentials)
    }

    public func download(item: FileShareItem, credentials: SignedInAccount, services: MCCServiceConfiguration) async throws -> FileShareDownload {
        guard item.accountEntityID == credentials.entityId, item.accountXUID == credentials.xuid else {
            throw PublisherError.authentication("This map belongs to a different signed-in account. Refresh your File Share.")
        }
        // A CDN URL may expire while the list is open. Retrieve it at download
        // time, and on an explicit expiry refusal retrieve fresh metadata once.
        for attempt in 0...1 {
            let raw = try await details(itemID: item.id, credentials: credentials, services: services)
            let url = try Self.contentURL(raw)
            do {
                let response = try await request(url: url, method: "GET")
                let mime = response.headers["content-type"]?.lowercased() ?? ""
                guard !mime.contains("json"), !mime.contains("html"), !mime.contains("xml") else {
                    throw PublisherError.protocolError("The content server returned an error document instead of a map. Refresh the File Share and try again.")
                }
                return try FileShareDownload(data: response.data, itemID: item.id)
            } catch let failure as HTTPStatusError where [401, 403].contains(failure.status) {
                if attempt == 0 { continue }
                throw PublisherError.service("The map's download link has expired. Refresh your File Share or sign in again.")
            }
        }
        throw PublisherError.service("The map's download link has expired. Refresh your File Share or sign in again.")
    }

    private func details(itemID: String, credentials: SignedInAccount, services: MCCServiceConfiguration) async throws -> JSONValue {
        try Self.validate(credentials)
        guard UUID(uuidString: itemID) != nil else { throw PublisherError.protocolError("The selected map has an invalid catalog ID. Refresh the File Share.") }
        try MCCServiceConfiguration.validate(services.itemLookup)
        let response = try await request(url: services.itemLookup, method: "POST", headers: [
            "X-EntityToken": credentials.entityToken, "Accept": "application/json", "Content-Type": "application/json",
        ], body: JSONValue.object(["ItemId": .string(itemID)]).encoded())
        let body = try Self.envelope(response.json)
        let raw = body["Item"]
        guard raw.object != nil else { throw PublisherError.service("This map is no longer available on the File Share. Refresh the list.") }
        guard Self.itemID(raw) == itemID.lowercased(), raw["ContentType"].string == "MapVariant",
              raw["CreatorEntity"]["Id"].string == credentials.entityId else {
            throw PublisherError.protocolError("MCC returned a different map or could not confirm that this account owns it. Refresh the File Share.")
        }
        return raw
    }

    private static func contentURL(_ raw: JSONValue) throws -> URL {
        guard let contents = raw["Contents"].array else { throw PublisherError.protocolError("This map has no downloadable data content.") }
        let dataContents = contents.filter { $0["Type"].string == "data" }
        // Older Xbox-migrated map items were observed with one untyped Url
        // instead of Type=data. Permit only one unambiguous untyped candidate;
        // never choose an explicitly identified thumbnail/image as map content.
        let untyped = contents.filter { $0.object != nil && ($0["Type"] == .null || $0["Type"] == .string("")) }
        let candidates = dataContents.isEmpty ? untyped : dataContents
        guard candidates.count == 1, let content = candidates.first,
              let address = content["Url"].string ?? content["DownloadUrl"].string,
              let url = URL(string: address), trustedDownloadURL(url) else {
            throw PublisherError.protocolError("This map did not provide one recognized HTTPS map-data download URL. A thumbnail cannot be saved as a map.")
        }
        return url
    }

    private func request(url: URL, method: String, headers: [String: String] = [:], body: Data? = nil) async throws -> HTTPResponse {
        do { return try await http.send(url: url, method: method, headers: headers, body: body) }
        catch is CancellationError { throw CancellationError() }
        catch let error as HTTPStatusError { throw error }
        catch let error as PublisherError { throw error }
        catch let error as URLError where error.code == .cancelled { throw CancellationError() }
        catch {
            // URLSession errors can carry the full scoped CDN URL. Do not put
            // those errors in UI state, logs or CLI output.
            throw PublisherError.service("The File Share request could not complete. Check your connection and try again.")
        }
    }

    static func trustedDownloadURL(_ url: URL) -> Bool {
        guard url.scheme == "https", url.user == nil, url.password == nil, url.fragment == nil,
              url.port == nil || url.port == 443, let host = url.host?.lowercased() else { return false }
        return host.hasSuffix(".blob.core.windows.net") || host.hasSuffix(".prod.catalog.playfab.com") ||
            host == "mcc-production.azurefd.net" || host == "xforgeassets002.xboxlive.com"
    }

    private static func validate(_ account: SignedInAccount) throws {
        guard account.expiresAt > Date(), !account.entityId.isEmpty, !account.xuid.isEmpty,
              !account.entityToken.isEmpty else { throw AuthError.signInRequired }
    }

    static func envelope(_ root: JSONValue) throws -> JSONValue {
        guard root.object != nil else { throw PublisherError.protocolError("MCC returned an invalid File Share response.") }
        guard root["data"] == .null || root["data"].object != nil else {
            throw PublisherError.protocolError("MCC returned an invalid File Share response envelope.")
        }
        let body = root["data"].object != nil ? root["data"] : root
        for value in [root, body] {
            if value["Error"] != .null || value["error"] != .null || value["errorCode"] != .null {
                throw PublisherError.service("MCC could not retrieve this File Share. The item may have been deleted or your session may have expired; refresh or sign in again.")
            }
            if value["code"] != .null, value["code"] != .number(200) {
                throw PublisherError.service("MCC refused the File Share request. Refresh or sign in again.")
            }
        }
        return body
    }

    private static func hasContinuation(_ body: JSONValue) -> Bool {
        for key in ["ContinuationToken", "continuationToken", "NextToken", "nextToken", "Continuation", "continuation", "NextLink", "nextLink"] {
            let value = body[key]
            if value != .null && value != .string("") { return true }
        }
        for key in ["HasMore", "hasMore", "HasMoreResults", "hasMoreResults"] where body[key] != .null && body[key] != .bool(false) { return true }
        return false
    }

    private static func itemID(_ row: JSONValue) -> String? {
        guard let id = row["Id"].string, UUID(uuidString: id) != nil else { return nil }
        return id.lowercased()
    }
    private static func nonnegativeInteger(_ value: JSONValue) -> Int? {
        guard let n = value.number, n.isFinite, n.rounded() == n, n >= 0, n < Double(Int.max) else { return nil }
        return Int(n)
    }
    private static func text(_ value: JSONValue) -> String? {
        if let s = value.string, !s.isEmpty { return s }
        return nil
    }
    private static func localized(_ value: JSONValue) -> String? {
        if let string = text(value) { return string }
        if let neutral = text(value["NEUTRAL"]) ?? text(value["neutral"]) { return neutral }
        guard let values = value.object else { return nil }
        return values.keys.sorted().compactMap { text(values[$0]!) }.first
    }
    private static func scalar(_ value: JSONValue) -> String? {
        text(value) ?? nonnegativeInteger(value).map(String.init)
    }
    private static func item(_ row: JSONValue, credentials: SignedInAccount) -> FileShareItem {
        let p = row["DisplayProperties"]
        let engine = scalar(p["GameEngine"])
        let mapID = scalar(p["BuiltInMapId"])
        let tags = row["Tags"].array?.compactMap(\.string) ?? []
        let names = ["0": "Halo: CE", "1": "Halo 2", "2": "Halo 3", "3": "Halo 4", "4": "Halo 2: Anniversary", "5": "Halo 3: ODST", "6": "Halo: Reach"]
        let game = engine.map { names[$0] ?? "MCC game \($0)" } ?? tags.first(where: { $0.hasPrefix("Halo") })
        let rawMap = tags.first(where: { $0.hasPrefix("_map_id_") })
        let baseMap = rawMap.map { $0.replacingOccurrences(of: "_map_id_", with: "").replacingOccurrences(of: "_", with: " ") }
            ?? mapID.map { "Map \($0)" }
        let size = scalar(p["FileSize"]).flatMap(Int.init).flatMap { $0 >= 0 ? $0 : nil }
        var date: Date?
        if let value = text(row["LastModifiedDate"]) ?? text(row["CreationDate"]) {
            let formatter = ISO8601DateFormatter(); formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            date = formatter.date(from: value)
            if date == nil { formatter.formatOptions = [.withInternetDateTime]; date = formatter.date(from: value) }
        }
        return FileShareItem(id: itemID(row)!, title: localized(row["Title"]) ?? "Untitled Map", description: localized(row["Description"]) ?? "",
            game: game, baseMap: baseMap, fileSize: size, modifiedAt: date, accountEntityID: credentials.entityId,
            accountXUID: credentials.xuid, gameEngine: engine, baseMapID: mapID)
    }
}

/// Structural export validation deliberately does not use the Reach upload
/// parser: MCC's other games and Reach versions use different map bodies.
/// Inflate only for inspection, then preserve the entire original byte buffer.
enum MapVariantDownloadValidator {
    static let maximumSize = 16 * 1024 * 1024
    static func validate(_ data: Data) throws {
        guard !data.isEmpty, data.count <= maximumSize else { throw invalid("The map is empty or exceeds the 16 MB limit.") }
        let bytes = [UInt8](data)
        guard bytes.count >= 48, String(bytes: bytes.prefix(4), encoding: .ascii) == "_blf" else {
            throw invalid("The server did not return an MCC BLF map file. No file was saved.")
        }
        var state = State()
        try scan(bytes, outer: true, depth: 0, state: &state)
        guard state.mapChunks == 1 else { throw invalid("The downloaded file does not contain exactly one map-variant payload.") }
    }
    private struct State { var mapChunks = 0; var expanded = 0 }
    private static func scan(_ bytes: [UInt8], outer: Bool, depth: Int, state: inout State) throws {
        guard depth <= 4 else { throw invalid("The map's compressed chunks are nested too deeply.") }
        var offset = 0, ended = false
        while offset < bytes.count {
            // Some authentic local files contain physical zero padding after EOF.
            if ended, bytes[offset...].allSatisfy({ $0 == 0 }) { break }
            guard bytes.count - offset >= 12 else { throw invalid("The downloaded BLF chunk header is truncated.") }
            let magic = String(bytes: bytes[offset..<offset + 4], encoding: .ascii) ?? ""
            let size = Int(be32(bytes, offset + 4))
            guard size >= 12, size <= bytes.count - offset else { throw invalid("A downloaded BLF chunk is truncated or has an invalid length.") }
            if offset == 0 && outer {
                guard magic == "_blf", size >= 48 else { throw invalid("The downloaded BLF envelope is invalid.") }
            }
            if ended {
                guard magic == "_fsm" else { throw invalid("The downloaded map has unexpected data after its BLF end marker.") }
            } else {
                switch magic {
                case "mvar", "mapv":
                    guard size > 12 else { throw invalid("The downloaded map-variant payload is empty.") }
                    state.mapChunks += 1
                case "_cmp":
                    guard size >= 17, bytes[offset + 12] == 0 else { throw invalid("The map uses an unsupported compressed BLF wrapper.") }
                    let length = Int(be32(bytes, offset + 13))
                    guard length > 0, length <= maximumSize - state.expanded else { throw invalid("The expanded map exceeds the 16 MB limit.") }
                    state.expanded += length
                    var output = [UInt8](repeating: 0, count: length)
                    var outputCount = uLongf(length), inputCount = uLong(size - 17)
                    let input = Array(bytes[offset + 17..<offset + size])
                    let result = output.withUnsafeMutableBufferPointer { out in input.withUnsafeBufferPointer { src in
                        uncompress2(out.baseAddress, &outputCount, src.baseAddress, &inputCount)
                    } }
                    guard result == Z_OK, outputCount == length, inputCount == input.count else { throw invalid("The downloaded compressed map is truncated or corrupt.") }
                    try scan(output, outer: false, depth: depth + 1, state: &state)
                case "_eof":
                    guard size >= 17 else { throw invalid("The downloaded BLF end marker is truncated.") }
                    // The outer end marker terminates the game-data envelope.
                    // Physical provenance/padding after it is opaque, as in the
                    // native core-prefix parser; preserve it without stripping.
                    if outer { return }
                    ended = true
                case "_blf":
                    guard offset == 0 else { throw invalid("The downloaded map contains an unexpected second BLF envelope.") }
                default: break
                }
            }
            offset += size
        }
        guard !outer || ended else { throw invalid("The downloaded map is missing its BLF end marker.") }
    }
    private static func be32(_ bytes: [UInt8], _ offset: Int) -> UInt32 {
        bytes[offset..<offset + 4].reduce(0) { ($0 << 8) | UInt32($1) }
    }
    private static func invalid(_ message: String) -> PublisherError { .invalidMap(message) }
}
