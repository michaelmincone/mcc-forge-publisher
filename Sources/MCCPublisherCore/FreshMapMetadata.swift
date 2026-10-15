import Foundation

public enum FreshMapMetadata {
    // MCC built-in enum/tag values corroborated against shipped Reach mapinfo resources.
    // Raw scenario IDs are not MCC catalog enums. Campaign and Firefight maps are excluded.
    private static let maps: [UInt32: (id: Int, tag: String)] = [
        1000: (196, "sword_base"), 1055: (193, "powerhouse"), 1200: (195, "spire"),
        1040: (197, "zealot"), 1020: (192, "countdown"), 1035: (190, "boardwalk"),
        1150: (194, "reflection"), 1080: (191, "boneyard"), 10020: (203, "battle_canyon"),
        10010: (204, "penance"), 10060: (207, "high_noon"), 10050: (208, "breakneck"),
        10070: (206, "solitary"), 10030: (205, "ridgeline"), 1500: (201, "condemned"),
        2002: (199, "breakpoint"), 2004: (200, "tempest"), 2001: (198, "anchor_9"),
        3006: (209, "forge_world"), 1510: (202, "highlands"),
    ]
    public static func makePlan(map: ReachMapDocument, account: SignedInAccount) throws -> UploadPlan {
        guard map.bytes.dropFirst(map.embeddedLength).allSatisfy({ $0 == 0 }) else {
            throw PublisherError.invalidMap("This file contains provenance or extra metadata that the publisher cannot preserve yet. Use a fresh unsigned export; the original file was not changed.")
        }
        guard let base = maps[map.mapID] else {
            throw PublisherError.invalidMap("This map's base scenario is not a supported Reach multiplayer map.")
        }
        guard !map.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw PublisherError.invalidMap("Give the map a name in your exporter before publishing.")
        }
        // Core bytes end at _eof. Local trailers, including _fsm, are not appended to the binary request.
        // Fresh publication does not claim or manufacture a signature for inherited provenance.
        // MCC's upstream upload initiation formats the local metadata GUID, rather than
        // using the human-readable source basename. Catalog Id is a separate server identity.
        let fileID = UUID().uuidString.lowercased()
        var properties: [String: JSONValue] = [
            "GameEngine": .string("6"), "FileSize": .string(String(map.embeddedLength)),
            // Fresh-save 0x1404d9584 supplies the signed-in XUID through
            // 0x140595010 → 0x140593d58 → 0x140593940 into metadata +0xc8.
            "CreatorId": .string(account.xuid), "BuiltInMapId": .string(String(base.id)),
            "FileName": .string(fileID),
        ]
        if map.creatorXUID != "0" { properties["AuthorXuid"] = .string(map.creatorXUID) }
        if map.modifierXUID != "0" { properties["EditorXuid"] = .string(map.modifierXUID) }
        let metadata = JSONValue.object([
            "Title": .object(["neutral": .string(map.title)]),
            "Description": .object(["neutral": .string(map.description)]),
            "DisplayProperties": .object(properties),
            "Platforms": .array([.string("2")]),
            "Tags": .array([.string("HaloReach"), .string("_map_id_haloreach_" + base.tag), .string("PC")]),
            "CreationDate": .string(""), "LastModifiedDate": .string(""), "StartDate": .string(""),
            "ETag": .string(""), "Id": .string(""), "Type": .string(""), "ContentType": .string("MapVariant"),
        ])
        return try UploadPlan(map: map, metadata: metadata, fileID: fileID, authorXUID: account.xuid)
    }
}
