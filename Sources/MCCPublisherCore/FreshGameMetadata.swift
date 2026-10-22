import Foundation

/// Fresh Reach gametype catalog metadata, recovered from MCC's game subtype
/// serializer (0x140592f04), tag descriptor (0x140593048), generic tag converter
/// (0x1404824e0), and Reach's category accessor (0x180067f04).
public enum FreshGameMetadata {
    public static func gameCategory(for gametype: ReachGameVariantDocument) throws -> (id: Int, tag: String) {
        if gametype.engineType == 4 { return (20, "GameCategory_Firefight") }
        if gametype.engineType == 1 && gametype.engineCategory == -1 { return (13, "GameCategory_Sandbox") }
        let categories: [Int: (Int, String)] = [
            0: (0, "CTF"), 1: (1, "Slayer"), 2: (2, "Oddball"),
            3: (3, "KOTH"), 4: (4, "Juggernaut"), 5: (15, "Territories"),
            6: (16, "Assault"), 7: (5, "Infection"), 8: (14, "VIP"),
            9: (23, "Invasion"), 10: (21, "Stockpile"), 11: (24, "ActionSack"),
            12: (7, "Race"), 13: (22, "Headhunter"), 16: (24, "ActionSack"),
            30: (26, "PreGameWarmUp"),
        ]
        guard let value = categories[gametype.engineCategory] else {
            throw PublisherError.invalidMap("MCC does not recognize this Reach gametype category. Choose a supported category in ReachVariantTool before uploading.")
        }
        return (value.0, "GameCategory_" + value.1)
    }

    public static func makePlan(gametype: ReachGameVariantDocument, account: SignedInAccount) throws -> UploadPlan {
        guard gametype.bytes.dropFirst(gametype.embeddedLength).allSatisfy({ $0 == 0 }) else {
            throw PublisherError.invalidMap("This gametype contains provenance or extra metadata that the publisher cannot preserve for a fresh upload. Use a fresh unsigned export; the original file was not changed.")
        }
        guard !gametype.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw PublisherError.invalidMap("Give the gametype a name in ReachVariantTool before uploading.")
        }
        let category = try gameCategory(for: gametype)
        let fileID = UUID().uuidString.lowercased()
        var properties: [String: JSONValue] = [
            "GameEngine": .string("6"), "FileSize": .string(String(gametype.embeddedLength)),
            "CreatorId": .string(account.xuid), "GameCategory": .string(String(category.id)),
            "FileName": .string(fileID),
        ]
        // MCC omits the optional IsForgeVariant property unless true.
        if gametype.engineType == 1 { properties["IsForgeVariant"] = .string("1") }
        if gametype.creatorXUID != "0" { properties["AuthorXuid"] = .string(gametype.creatorXUID) }
        if gametype.modifierXUID != "0" { properties["EditorXuid"] = .string(gametype.modifierXUID) }
        let metadata = JSONValue.object([
            "Title": .object(["neutral": .string(gametype.title)]),
            "Description": .object(["neutral": .string(gametype.description)]),
            "DisplayProperties": .object(properties),
            "Platforms": .array([.string("2")]),
            "Tags": .array([.string("HaloReach"), .string(category.tag), .string("PC")]),
            "CreationDate": .string(""), "LastModifiedDate": .string(""), "StartDate": .string(""),
            "ETag": .string(""), "Id": .string(""), "Type": .string(""), "ContentType": .string("GameVariant"),
        ])
        return try UploadPlan(variant: .gametype(gametype), metadata: metadata, fileID: fileID, authorXUID: account.xuid)
    }
}

public enum FreshVariantMetadata {
    public static func makePlan(variant: ReachVariantDocument, account: SignedInAccount) throws -> UploadPlan {
        switch variant {
        case .map(let map): return try FreshMapMetadata.makePlan(map: map, account: account)
        case .gametype(let game): return try FreshGameMetadata.makePlan(gametype: game, account: account)
        }
    }
}
