import Foundation

public struct UploadPlan: Sendable {
    public let map: ReachMapDocument
    public let metadata: JSONValue
    public let fileID: String
    public let authorXUID: String
    public var payload: Data { Data(map.bytes.prefix(map.embeddedLength)) }

    public init(map: ReachMapDocument, metadata: JSONValue, fileID: String, authorXUID: String) throws {
        guard UInt64(authorXUID) != nil, !fileID.isEmpty, fileID.count <= 128,
              fileID.rangeOfCharacter(from: .newlines) == nil else {
            throw PublisherError.protocolError("The publishing identity or file identifier is invalid.")
        }
        self.map = map; self.metadata = metadata; self.fileID = fileID; self.authorXUID = authorXUID
    }

    public func request(credentials: SignedInAccount, services: MCCServiceConfiguration) throws -> (headers: [String: String], body: Data) {
        guard credentials.xuid == authorXUID else { throw PublisherError.authentication("Sign in with the account that prepared this upload.") }
        let suffix = try metadata.encoded()
        var body = payload; body.append(suffix)
        let headers = [
            "Content-Type": "application/octet-stream", "Accept": "application/json",
            "EntityToken": credentials.entityToken, "x-auth-token": credentials.sessionTicket,
            "FileName": fileID, "ContentLength": String(payload.count), "MetadataLength": String(suffix.count),
            "AuthorFileXuid": authorXUID, "Sandbox": services.sandbox,
        ]
        return (headers, body)
    }
}

public struct PublicationReceipt: Sendable, Codable {
    public let itemID: String
    public let title: String
    public let publishedAt: Date
    public let downloadVerified: Bool
    public let fileSHA256: String
    public init(itemID: String, title: String, publishedAt: Date, downloadVerified: Bool, fileSHA256: String) {
        self.itemID = itemID; self.title = title; self.publishedAt = publishedAt
        self.downloadVerified = downloadVerified; self.fileSHA256 = fileSHA256
    }
}
