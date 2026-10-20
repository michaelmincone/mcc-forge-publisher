import Foundation

public struct MCCServiceConfiguration: Codable, Sendable, Equatable {
    public let upload: URL
    public let permission: URL
    public let itemLookup: URL
    public let itemListing: URL
    public let itemDeletion: URL
    public let sandbox: String
    public let source: String

    public init(upload: URL, permission: URL, itemLookup: URL = URL(string: "https://mcc-production.azurefd.net/api/GetPlayFabUgcItem")!,
                itemListing: URL = URL(string: "https://mcc-production.azurefd.net/api/GetPlayFabUgcItems")!,
                itemDeletion: URL = URL(string: "https://mcc-production.azurefd.net/api/DeletePlayFabUgcItem")!,
                sandbox: String = "RETAIL", source: String) throws {
        for url in [upload, permission, itemLookup, itemListing, itemDeletion] { try Self.validate(url) }
        guard sandbox == "RETAIL" else { throw PublisherError.protocolError("Only the RETAIL MCC File Share is supported.") }
        self.upload = upload; self.permission = permission; self.itemLookup = itemLookup; self.itemListing = itemListing
        self.itemDeletion = itemDeletion
        self.sandbox = sandbox; self.source = source
    }

    // Existing saved settings predate File Share browsing. Decode through the
    // validating initializer rather than allowing Codable to bypass host checks.
    private enum CodingKeys: String, CodingKey { case upload, permission, itemLookup, itemListing, itemDeletion, sandbox, source }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(upload: c.decode(URL.self, forKey: .upload), permission: c.decode(URL.self, forKey: .permission),
            itemLookup: c.decodeIfPresent(URL.self, forKey: .itemLookup) ?? URL(string: "https://mcc-production.azurefd.net/api/GetPlayFabUgcItem")!,
            itemListing: c.decodeIfPresent(URL.self, forKey: .itemListing) ?? URL(string: "https://mcc-production.azurefd.net/api/GetPlayFabUgcItems")!,
            itemDeletion: c.decodeIfPresent(URL.self, forKey: .itemDeletion) ?? URL(string: "https://mcc-production.azurefd.net/api/DeletePlayFabUgcItem")!,
            sandbox: c.decodeIfPresent(String.self, forKey: .sandbox) ?? "RETAIL", source: c.decode(String.self, forKey: .source))
    }

    public static func validate(_ url: URL) throws {
        let host = url.host?.lowercased() ?? ""
        let allowed = host == "mcc-production.azurefd.net" || host.hasSuffix(".svc.halowaypoint.com")
        guard allowed, url.scheme == "https", url.user == nil, url.password == nil, url.query == nil, url.fragment == nil,
              url.port == nil || url.port == 443 else {
            throw PublisherError.protocolError("The publishing endpoint must be an HTTPS MCC service. Credentials will not be sent to this host.")
        }
    }

    // The endpoint names and Authorities structure were recovered from MCC's service initializer.
    public static func discovered(from root: JSONValue, source: String) throws -> Self {
        let payload = root["Endpoints"].object != nil ? root : root["data"]
        guard let endpoints = payload["Endpoints"].object, let authorities = payload["Authorities"].object else {
            throw PublisherError.protocolError("MCC service discovery returned no endpoint configuration.")
        }
        func endpoint(_ name: String) throws -> URL {
            guard let row = endpoints[name], let id = row["AuthorityId"].string,
                  authorities[id]?["Scheme"].int == 2, authorities[id]?["Port"].int == 443,
                  let host = authorities[id]?["Hostname"].string, let path = row["Path"].string,
                  path.hasPrefix("/"), !path.hasPrefix("//"), !host.contains("/"),
                  let url = URL(string: "https://" + host + path) else {
                throw PublisherError.protocolError("MCC service discovery did not provide \(name).")
            }
            try validate(url); return url
        }
        // Older saved/offline service documents may lack the read-only routes.
        // If discovery does supply them, honor and validate their authorities.
        let lookup: URL
        if endpoints["PlayFab_GetPublishedItem"] != nil { lookup = try endpoint("PlayFab_GetPublishedItem") }
        else if endpoints["MCCAzureFunctions_GetPlayFabUgcItem"] != nil { lookup = try endpoint("MCCAzureFunctions_GetPlayFabUgcItem") }
        else { lookup = URL(string: "https://mcc-production.azurefd.net/api/GetPlayFabUgcItem")! }
        let listing = endpoints["MCCAzureFunctions_GetPlayFabUgcItems"] == nil
            ? URL(string: "https://mcc-production.azurefd.net/api/GetPlayFabUgcItems")!
            : try endpoint("MCCAzureFunctions_GetPlayFabUgcItems")
        let deletion = endpoints["PlayFab_DeleteDraftItem"] == nil
            ? URL(string: "https://mcc-production.azurefd.net/api/DeletePlayFabUgcItem")!
            : try endpoint("PlayFab_DeleteDraftItem")
        return try Self(upload: endpoint("MCCAzureFunctions_UploadFile"), permission: endpoint("MCCAzureFunctions_GetUploadPermission"),
                        itemLookup: lookup, itemListing: listing, itemDeletion: deletion, source: source)
    }
}
