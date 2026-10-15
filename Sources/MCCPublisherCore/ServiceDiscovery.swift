import Foundation

public struct ServiceDiscovery: Sendable {
    public let http: HTTPClient
    public init(http: HTTPClient = HTTPClient()) { self.http = http }
    public func resolve(account: SignedInAccount, saved: MCCServiceConfiguration?) async throws -> MCCServiceConfiguration {
        if let saved {
            return try MCCServiceConfiguration(upload: saved.upload, permission: saved.permission, itemLookup: saved.itemLookup, sandbox: saved.sandbox, source: saved.source)
        }
        let url = URL(string: "https://settings.svc.halowaypoint.com/settings/hmccpc/9d6dbeddd8bc478f92c6a6fac6424ca7")!
        let response = try await http.send(url: url, method: "GET", headers: ["Accept": "application/json"])
        return try MCCServiceConfiguration.discovered(from: response.json, source: url.absoluteString)
    }
}
