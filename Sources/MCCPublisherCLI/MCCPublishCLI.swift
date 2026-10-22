import Foundation
import MCCPublisherCore
import CryptoKit
import Darwin

@main
struct MCCPublishCLI {
    static func main() async {
        do {
            let args = Array(CommandLine.arguments.dropFirst())
            if args.first == "list", args.count <= 2 {
                try await browseOwnShare(search: args.count == 2 ? args[1] : "")
                return
            }
            if args.count == 3, args[0] == "download" {
                try await browseOwnShare(itemID: args[1], destination: URL(fileURLWithPath: args[2]))
                return
            }
            if args.count == 2, args[0] == "inspect" {
                let variant = try ReachVariantDocument.load(from: URL(fileURLWithPath: args[1]))
                var fields: [String: JSONValue] = [
                    "title": .string(variant.title), "description": .string(variant.description), "game": .string("HaloReach"),
                    "kind": .string(variant.kind.rawValue), "fileBytes": .number(Double(variant.bytes.count)),
                    "embeddedBlfBytes": .number(Double(variant.embeddedLength)), "trailingBytes": .number(Double(variant.trailingByteCount)),
                    "sha256": .string(variant.sha256),
                ]
                switch variant {
                case .map(let map): fields["scenarioMapId"] = .number(Double(map.mapID)); fields["bodyVersion"] = .number(Double(map.bodyVersion))
                case .gametype(let game):
                    fields["engineCategory"] = .number(Double(game.engineCategory))
                    fields["headerEngineCategory"] = .number(Double(game.headerEngineCategory))
                    fields["engineType"] = .number(Double(game.engineType)); fields["bodyVersion"] = .number(Double(game.bodyVersion))
                    if let category = try? FreshGameMetadata.gameCategory(for: game) {
                        fields["mccGameCategory"] = .number(Double(category.id)); fields["categoryTag"] = .string(category.tag)
                    }
                }
                print(String(decoding: try JSONValue.object(fields).encoded(), as: UTF8.self))
                return
            }
            if args.count == 3, args[0] == "upload-control" {
                let map = try ReachMapDocument.load(from: URL(fileURLWithPath: args[1]))
                try await uploadControl(map, title: args[2])
                return
            }
            if args.count == 3, args[0] == "diagnose-own", UUID(uuidString: args[2]) != nil {
                let map = try ReachMapDocument.load(from: URL(fileURLWithPath: args[1]))
                try await diagnoseOwn(map, itemID: args[2])
                return
            }
            guard args.count == 2, ["inspect", "verify-own", "repair-own-filename", "repair-catalog-filename"].contains(args[0]) else {
                print("Usage: mcc-publish inspect /absolute/path/to/map.mvar-or-gametype.bin")
                print("       mcc-publish verify-own /absolute/path/to/map.mvar (read-only)")
                print("       mcc-publish list [SEARCH] (read-only File Share browser)")
                print("       mcc-publish download ITEM_ID /absolute/path/to/map.mvar-or-gametype.bin")
                print("Sign-in and publishing are available in MCC Forge Publisher.app.")
                return
            }
            let map = try ReachMapDocument.load(from: URL(fileURLWithPath: args[1]))
            if args[0] != "inspect" {
                try await verifyOwn(map, repairFilename: args[0] == "repair-own-filename", catalogRepair: args[0] == "repair-catalog-filename")
                return
            }
            let result = JSONValue.object([
                "title": .string(map.title), "description": .string(map.description), "game": .string("HaloReach"),
                "scenarioMapId": .number(Double(map.mapID)), "bodyVersion": .number(Double(map.bodyVersion)),
                "fileBytes": .number(Double(map.bytes.count)), "embeddedBlfBytes": .number(Double(map.embeddedLength)),
                "trailingBytes": .number(Double(map.trailingByteCount)), "sha256": .string(map.sha256),
            ])
            print(String(decoding: try result.encoded(), as: UTF8.self))
        } catch {
            FileHandle.standardError.write(Data((error.localizedDescription + "\n").utf8)); exit(1)
        }
    }

    /// Uses the same core browser as the app, without writing credentials or publication receipts.
    private static func browseOwnShare(itemID: String? = nil, destination: URL? = nil, search: String = "") async throws {
        guard let account = try await AuthService(persistsCredentials: false).restoreSession() else {
            throw PublisherError.authentication("Sign in using the native app first.")
        }
        let http = HTTPClient()
        let services = try await ServiceDiscovery(http: http).resolve(account: account, saved: nil)
        let service = FileShareService(http: http)
        let listing = try await service.list(credentials: account, services: services)
        if let itemID, let destination {
            guard !FileManager.default.fileExists(atPath: destination.path) else {
                throw PublisherError.service("The destination already exists. Choose another filename.")
            }
            guard let item = listing.items.first(where: { $0.id == itemID }) else {
                throw PublisherError.service(listing.isComplete ? "That file is not on this account's File Share." : "That file was not found in the incomplete File Share results. Refresh in the app.")
            }
            guard destination.pathExtension.lowercased() == item.kind.fileExtension else {
                throw PublisherError.invalidMap("Choose a destination with the .\(item.kind.fileExtension) extension.")
            }
            let downloaded = try await service.download(item: item, credentials: account, services: services)
            try downloaded.save(to: destination)
            print(String(decoding: try JSONValue.object([
                "savedPath": .string(destination.path), "bytes": .number(Double(downloaded.data.count)),
                "sha256": .string(downloaded.sha256), "itemID": .string(item.id)
            ]).encoded(), as: UTF8.self))
        } else {
            let items = listing.items.filter { $0.matches(search: search) }.map { item in
                JSONValue.object([
                    "id": .string(item.id), "title": .string(item.title),
                    "kind": .string(item.kind.rawValue),
                    "game": item.game.map { .string($0) } ?? .null,
                    "baseMap": item.baseMap.map { .string($0) } ?? .null,
                    "fileBytes": item.fileSize.map { .number(Double($0)) } ?? .null,
                    "modifiedAt": item.modifiedAt.map { .string(ISO8601DateFormatter().string(from: $0)) } ?? .null
                ])
            }
            print(String(decoding: try JSONValue.object([
                "complete": .bool(listing.isComplete), "warning": listing.warning.map { .string($0) } ?? .null,
                "items": .array(items)
            ]).encoded(), as: UTF8.self))
        }
    }

    private static func diagnoseOwn(_ map: ReachMapDocument, itemID: String) async throws {
        guard let account = try await AuthService(persistsCredentials: false).restoreSession() else {
            throw PublisherError.authentication("Sign in using the native app first.")
        }
        let http = HTTPClient()
        let services = try await ServiceDiscovery(http: http).resolve(account: account, saved: nil)
        let details = try await http.send(url: services.itemLookup, method: "POST",
            headers: ["X-EntityToken": account.entityToken, "Content-Type": "application/json"],
            body: JSONValue.object(["ItemId": .string(itemID)]).encoded())
        let item = details.json["data"]["Item"].object != nil ? details.json["data"]["Item"] : details.json["Item"]
        print("MCC item response fields: \((details.json.object?.keys.sorted() ?? []).joined(separator: ",")); published Id matches=\(item["Id"].string == itemID); owner field present=\(item["CreatorEntity"].object != nil).")
        let draftResponse = try await http.send(url: URL(string: "https://ee38.playfabapi.com/Catalog/GetDraftItem")!, method: "POST",
            headers: ["X-EntityToken": account.entityToken, "Content-Type": "application/json"],
            body: JSONValue.object(["Id": .string(itemID)]).encoded())
        let draft = draftResponse.json["data"]["Item"]
        guard draft["Id"].string == itemID, draft["CreatorEntity"]["Id"].string == account.entityId else {
            throw PublisherError.protocolError("The requested draft is not owned by this signed-in account.")
        }
        let status = try await http.send(url: URL(string: "https://ee38.playfabapi.com/Catalog/GetItemPublishStatus")!, method: "POST",
            headers: ["X-EntityToken": account.entityToken, "Content-Type": "application/json"],
            body: JSONValue.object(["Id": .string(itemID)]).encoded())
        print("Catalog publish status: \(status.json["data"]["Result"].string ?? "unknown"); status message length=\(status.json["data"]["StatusMessage"].string?.count ?? 0).")
        print("Draft: type=\(draft["Type"].string ?? "missing"), ContentType=\(draft["ContentType"].string ?? "missing"), Title keys=\((draft["Title"].object?.keys.sorted() ?? []).joined(separator: ",")).")
        printContents(draft, label: "Draft")
        print("Owned target exists; catalog type=\(item["Type"].string ?? "missing"), ContentType=\(item["ContentType"].string ?? "missing"), Title keys=\((item["Title"].object?.keys.sorted() ?? []).joined(separator: ",")), Platforms=\(item["Platforms"].array?.compactMap(\.string).joined(separator: ",") ?? "missing").")
        print("Target field names: \((item.object?.keys.sorted() ?? []).joined(separator: ",")).")
        print("Target display property names: \((item["DisplayProperties"].object?.keys.sorted() ?? []).joined(separator: ",")).")
        printContents(item, label: "Target")
        let hash = SHA256.hash(data: Data(map.bytes.prefix(map.embeddedLength))).map { String(format: "%02x", $0) }.joined()
        let receipt = PublicationReceipt(itemID: itemID, title: map.title, publishedAt: Date(), downloadVerified: false, fileSHA256: hash)
        do {
            let verified = try await PublisherService(http: http).verifyDownload(receipt: receipt, credentials: account, services: services)
            print("Target stored core SHA256 matches the source.")
            try saveReceipt(verified, accountXUID: account.xuid)
        } catch { print("Target readback: \(error.localizedDescription)") }
        let list = try await http.send(url: URL(string: "https://mcc-production.azurefd.net/api/GetPlayFabUgcItems")!, method: "POST",
            headers: ["Accept": "application/json", "CreatorEntityId": account.entityId, "UserEntityId": account.entityId], body: Data("{}".utf8))
        let items = list.json["Items"].array ?? list.json["data"]["Items"].array ?? []
        print("List includes target: \(items.contains(where: { $0["Id"].string == itemID })).")
        if let reference = items.first(where: { $0["Id"].string != itemID && $0["ContentType"].string == "MapVariant" && $0["DisplayProperties"]["GameEngine"].string == "6" }),
           let id = reference["Id"].string {
            let response = try await http.send(url: services.itemLookup, method: "POST",
                headers: ["X-EntityToken": account.entityToken, "Content-Type": "application/json"],
                body: JSONValue.object(["ItemId": .string(id)]).encoded())
            let row = response.json["data"]["Item"].object != nil ? response.json["data"]["Item"] : response.json["Item"]
            print("Reach reference: type=\(row["Type"].string ?? "missing"), ContentType=\(row["ContentType"].string ?? "missing"), Platforms=\(row["Platforms"].array?.compactMap(\.string).joined(separator: ",") ?? "missing").")
            print("Reference display property names: \((row["DisplayProperties"].object?.keys.sorted() ?? []).joined(separator: ",")).")
            printContents(row, label: "Reference")
        }
    }

    private static func uploadControl(_ map: ReachMapDocument, title: String) async throws {
        guard !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, title.utf16.count <= 128 else {
            throw PublisherError.invalidMap("The control title is invalid.")
        }
        guard let account = try await AuthService(persistsCredentials: false).restoreSession() else {
            throw PublisherError.authentication("Sign in using the native app first.")
        }
        let hash = SHA256.hash(data: Data(map.bytes.prefix(map.embeddedLength))).map { String(format: "%02x", $0) }.joined()
        let historyURL = historyURL()
        if let raw = try? Data(contentsOf: historyURL), let history = try? JSONDecoder().decode(JSONValue.self, from: raw),
           (history["receipts"].array ?? []).contains(where: { $0["accountXUID"].string == account.xuid && $0["receipt"]["fileSHA256"].string == hash }) {
            throw PublisherError.protocolError("This account already has a saved receipt for this exact control. No duplicate was uploaded.")
        }
        let http = HTTPClient()
        let services = try await ServiceDiscovery(http: http).resolve(account: account, saved: nil)
        let fresh = try FreshMapMetadata.makePlan(map: map, account: account)
        var metadata = fresh.metadata.object!
        metadata["Title"] = .object(["neutral": .string(title)])
        let plan = try UploadPlan(map: map, metadata: .object(metadata), fileID: fresh.fileID, authorXUID: account.xuid)
        let result = try await PublisherService(http: http).upload(plan: plan, credentials: account, services: services)
        let receipt = PublicationReceipt(itemID: result.itemID, title: title, publishedAt: result.publishedAt,
            downloadVerified: false, fileSHA256: result.fileSHA256)
        try saveReceipt(receipt, accountXUID: account.xuid)
        print("Published one original control as \(title); itemID=\(receipt.itemID). Source bytes unchanged.")
        do {
            let verified = try await PublisherService(http: http).verifyDownload(receipt: receipt, credentials: account, services: services)
            try saveReceipt(verified, accountXUID: account.xuid)
            print("Stored control core SHA256 matches the original. Xbox download remains to test.")
        } catch { print("Control readback pending: \(error.localizedDescription). No upload retry was attempted.") }
    }

    private static func historyURL() -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("MCCForgePublisher/publications.json")
    }

    private static func saveReceipt(_ receipt: PublicationReceipt, accountXUID: String) throws {
        let url = historyURL()
        var entries: [JSONValue] = []
        if FileManager.default.fileExists(atPath: url.path) {
            let size = try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber
            guard let size, size.uint64Value <= 4 * 1024 * 1024 else { throw PublisherError.protocolError("Publication history is too large.") }
            let document = try JSONDecoder().decode(JSONValue.self, from: Data(contentsOf: url))
            guard document["schemaVersion"].int == 1, let prior = document["receipts"].array else {
                throw PublisherError.protocolError("Publication history could not be read.")
            }
            entries = prior.filter { !($0["accountXUID"].string == accountXUID && $0["receipt"]["itemID"].string == receipt.itemID) }
        }
        entries.append(.object(["accountXUID": .string(accountXUID), "receipt": .object([
            "itemID": .string(receipt.itemID), "title": .string(receipt.title),
            "publishedAt": .string(ISO8601DateFormatter().string(from: receipt.publishedAt)),
            "downloadVerified": .bool(receipt.downloadVerified), "fileSHA256": .string(receipt.fileSHA256)
        ])]))
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let temporary = url.deletingLastPathComponent().appendingPathComponent(".receipt-\(UUID().uuidString).tmp")
        defer { try? FileManager.default.removeItem(at: temporary) }
        let data = try JSONValue.object(["schemaVersion": .number(1), "receipts": .array(entries)]).encoded()
        guard FileManager.default.createFile(atPath: temporary.path, contents: data, attributes: [.posixPermissions: 0o600]),
              rename(temporary.path, url.path) == 0 else { throw PublisherError.service("The receipt could not be saved. Check File Share before retrying.") }
    }

    private static func printContents(_ item: JSONValue, label: String) {
        for content in item["Contents"].array ?? [] {
            let host = content["Url"].string.flatMap { URL(string: $0)?.host } ?? "missing"
            print("\(label) content: fields=\((content.object?.keys.sorted() ?? []).joined(separator: ",")); Type=\(content["Type"].string ?? "missing"); Tags=\(content["Tags"].array?.compactMap(\.string).joined(separator: ",") ?? "missing"); versions=\(content["MinClientVersion"].string ?? "none")..\(content["MaxClientVersion"].string ?? "none"); host=\(host).")
        }
    }

    private static func verifyOwn(_ map: ReachMapDocument, repairFilename: Bool = false, catalogRepair: Bool = false) async throws {
        guard let account = try await AuthService(persistsCredentials: false).restoreSession() else {
            throw PublisherError.authentication("Sign in using the native app first.")
        }
        let http = HTTPClient()
        let services = try await ServiceDiscovery(http: http).resolve(account: account, saved: nil)
        let list = try await http.send(url: URL(string: "https://mcc-production.azurefd.net/api/GetPlayFabUgcItems")!, method: "POST",
            headers: ["Accept": "application/json", "CreatorEntityId": account.entityId, "UserEntityId": account.entityId], body: Data("{}".utf8))
        let items = list.json["Items"].array ?? list.json["data"]["Items"].array ?? []
        for item in items {
            let p = item["DisplayProperties"]
            let name = p["FileName"].string ?? ""
            let noExtension = (name as NSString).deletingPathExtension
            let kind = UUID(uuidString: name) != nil ? "UUID" : UUID(uuidString: noExtension) != nil ? "UUID+extension" : "non-UUID"
            let same = (item["Title"]["NEUTRAL"].string ?? item["Title"]["neutral"].string) == map.title
            print("Catalog \(same ? "target" : "reference"): type=\(item["ContentType"].string ?? "unknown"), filename=\(kind), creatorZero=\(p["CreatorId"].string == "0"), authorTime=\(p["AuthorTime"].string != nil), editorTime=\(p["EditorTime"].string != nil), provenance=\(p["FileAdditionalMetadata"].string != nil), game=\(p["GameEngine"].string ?? "missing"), map=\(p["BuiltInMapId"].string ?? "missing").")
        }
        let matches = items.filter {
            ($0["Title"]["NEUTRAL"].string ?? $0["Title"]["neutral"].string) == map.title && $0["ContentType"].string == "MapVariant"
        }
        print("Own File Share contains \(items.count) items; \(matches.count) matching map(s).")
        let hash = SHA256.hash(data: Data(map.bytes.prefix(map.embeddedLength))).map { String(format: "%02x", $0) }.joined()
        if repairFilename || catalogRepair {
            guard matches.count == 1, let existing = matches.first, let id = existing["Id"].string,
                  UUID(uuidString: id) != nil, existing["CreatorEntity"]["Id"].string == account.entityId else {
                throw PublisherError.protocolError("Repair requires exactly one matching item owned by the signed-in account.")
            }
            let prior = PublicationReceipt(itemID: id, title: map.title, publishedAt: Date(), downloadVerified: false, fileSHA256: hash)
            _ = try await PublisherService(http: http).verifyDownload(receipt: prior, credentials: account, services: services)
            try await PublisherService(http: http).checkPermission(credentials: account, services: services)
            if catalogRepair {
                let base = "https://ee38.playfabapi.com/Catalog/"
                let draft = try await http.send(url: URL(string: base + "GetDraftItem")!, method: "POST",
                    headers: ["X-EntityToken": account.entityToken, "Content-Type": "application/json"],
                    body: JSONValue.object(["Id": .string(id)]).encoded())
                var item = draft.json["data"]["Item"].object ?? [:]
                guard item["Id"]?.string == id, item["CreatorEntity"]?["Id"].string == account.entityId,
                      item["Contents"]?.array?.isEmpty == false else { throw PublisherError.protocolError("No owned draft with the same content was returned.") }
                var p = item["DisplayProperties"]?.object ?? [:]; p["FileName"] = .string(id)
                item["DisplayProperties"] = .object(p)
                let updated = try await http.send(url: URL(string: base + "UpdateDraftItem")!, method: "POST",
                    headers: ["X-EntityToken": account.entityToken, "Content-Type": "application/json"],
                    body: JSONValue.object(["Item": .object(item), "Publish": .bool(true)]).encoded())
                guard updated.json["data"]["Item"]["Id"].string == id else { throw PublisherError.protocolError("The catalog did not confirm the same updated item ID.") }
                print("Updated only filename metadata on existing catalog item \(id); binary content references unchanged.")
                return
            }
            var properties = existing["DisplayProperties"].object ?? [:]
            properties["FileName"] = .string(id)
            properties["FileSize"] = .string(String(map.embeddedLength))
            var metadata: [String: JSONValue] = [:]
            for key in ["Title", "Description", "Platforms", "Tags", "CreationDate", "LastModifiedDate", "StartDate", "Type", "ContentType"] {
                metadata[key] = existing[key] == .null ? .string("") : existing[key]
            }
            metadata["DisplayProperties"] = .object(properties)
            metadata["ETag"] = .string(""); metadata["Id"] = .string(id)
            let suffix = try JSONValue.object(metadata).encoded()
            var body = Data(map.bytes.prefix(map.embeddedLength)); body.append(suffix)
            var headers = ["Content-Type": "application/octet-stream", "Accept": "application/json",
                "EntityToken": account.entityToken, "x-auth-token": account.sessionTicket,
                "FileName": id, "ContentLength": String(map.embeddedLength), "MetadataLength": String(suffix.count),
                "AuthorFileXuid": account.xuid, "Sandbox": services.sandbox]
            if let provenance = existing["DisplayProperties"]["FileAdditionalMetadata"].string { headers["FileAdditionalMetadata"] = provenance }
            let response = try await http.send(url: services.upload, method: "PUT", headers: headers, body: body)
            guard response.json["result"].string == "success", response.json["fileId"].string == id else {
                throw PublisherError.protocolError("Repair did not confirm the original item ID. No further write will be attempted.")
            }
            print("Updated filename to a UUID on the existing item \(id); map bytes unchanged.")
            return
        }
        for item in matches {
            guard let id = item["Id"].string else { continue }
            let receipt = PublicationReceipt(itemID: id, title: map.title, publishedAt: Date(), downloadVerified: false, fileSHA256: hash)
            do {
                _ = try await PublisherService(http: http).verifyDownload(receipt: receipt, credentials: account, services: services)
                print("Verified uploaded core SHA256 for item \(id).")
                return
            } catch {
                print("Read-back for item \(id): \(error.localizedDescription)")
                let details = try await http.send(url: services.itemLookup, method: "POST", headers: ["X-EntityToken": account.entityToken, "Content-Type": "application/json"],
                    body: JSONValue.object(["ItemId": .string(id)]).encoded())
                let row = details.json["data"]["Item"].object != nil ? details.json["data"]["Item"] : details.json["Item"]
                let contents = row["Contents"].array ?? []
                let content = contents.first(where: { $0["Type"].string == "data" }) ?? contents.first
                let raw = row["DownloadUrl"].string ?? content?["Url"].string ?? content?["DownloadUrl"].string
                print("Item fields: \((row.object?.keys.sorted() ?? []).joined(separator: ",")); download host: \(raw.flatMap { URL(string: $0)?.host } ?? "missing").")
                print("Data-content field names: \((content?.object?.keys.sorted() ?? []).joined(separator: ",")); FileName: \(row["DisplayProperties"]["FileName"].string ?? "missing"); FileSize: \(row["DisplayProperties"]["FileSize"].string ?? "missing").")
            }
        }
        throw PublisherError.protocolError("No matching downloadable map was verified; no upload was attempted.")
    }
}
