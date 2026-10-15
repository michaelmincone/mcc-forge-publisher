import Foundation
import CryptoKit

/// Interactive authentication using the documented public compatibility profile.
/// No password, cookie, other-app token, alternate-client retry, or key rotation.
public actor AuthService {
    private let http: HTTPClient
    private let vault: any CredentialVault
    private let configuration: AuthConfiguration
    private let persistsCredentials: Bool
    private var stored: (vault: StoredVault, data: Data?)?
    private var pending: PendingSignIn?
    private var inProgress = false
    private var generation: UInt64 = 0
    private var operationGeneration: UInt64 = 0
    private var refreshTask: Task<SignedInAccount?, Error>?

    /// `persistsCredentials: false` uses the saved sign-in without changing it (for tools other than the app).
    public init(http: HTTPClient = HTTPClient(), vault: any CredentialVault = KeychainStore(),
                configuration: AuthConfiguration = .mcc, persistsCredentials: Bool = true) {
        self.http = http; self.vault = vault; self.configuration = configuration
        self.persistsCredentials = persistsCredentials
    }

    /// True when this build has not saved its own copy of an earlier build's sign-in yet, so macOS
    /// will ask once before this build can read it.
    public func savedSignInNeedsApproval() -> Bool {
        guard stored == nil else { return false }
        let prefixes = Self.accountPrefixes(for: configuration), saved = vault.accounts(withPrefix: prefixes.current)
        if saved.isEmpty { return !vault.accounts(withPrefix: prefixes.legacy).isEmpty }
        return !saved.contains(prefixes.current + vault.ownerTag)
    }

    public func beginSignIn() async throws -> SignInChallenge {
        try startOperation(); defer { inProgress = false }
        try validateConfiguration()
        pending = nil
        let identity = try deviceIdentity()
        let pkce = try PKCE.generate()
        let state = try secureRandomData(count: 32).base64URLString
        let device = try await deviceToken(identity)
        let session = try await sisuSession(device: device, pkce: pkce, state: state, identity: identity)
        guard let url = URL(string: session.redirect), url.scheme == "https",
              ["login.live.com", "login.microsoftonline.com", "sisu.xboxlive.com"].contains(url.host?.lowercased() ?? ""),
              url.user == nil, url.password == nil else {
            throw AuthError.browserRedirectRejected(BrowserAuthorizationDiagnostic(redirect: session.redirect,
                responsePropertyNames: session.propertyNames, responseHeaderNames: session.headerNames))
        }
        try checkOperation()
        let challenge = SignInChallenge(url: url, state: state, redirectURI: configuration.redirectURI)
        pending = PendingSignIn(challenge: challenge, verifier: pkce.verifier, sessionID: session.id,
                                identity: identity, createdAt: Date())
        return challenge
    }

    public func completeSignIn(callback: URL) async throws -> SignedInAccount {
        try startOperation(); defer { inProgress = false }
        guard let signIn = pending else { throw AuthError.invalidCallback("no pending sign-in") }
        guard Date().timeIntervalSince(signIn.createdAt) < 15 * 60 else {
            pending = nil; throw AuthError.invalidCallback("sign-in expired")
        }
        let code: String
        do {
            code = try OAuthCallback.authorizationCode(from: callback, redirectURI: configuration.redirectURI,
                                                       expectedState: signIn.challenge.state)
        } catch let refusal as AuthError {
            switch refusal {
            case .cancelled, .authorizationDenied: pending = nil
            default: break
            }
            throw refusal
        }
        pending = nil // The accepted callback is single-use, including after a network error.
        let msa: MicrosoftTokenReply = try await formRequest(stage: "Microsoft code redemption", values: [
            ("client_id", configuration.clientID), ("code", code), ("code_verifier", signIn.verifier),
            ("grant_type", "authorization_code"), ("redirect_uri", configuration.redirectURI.absoluteString),
            ("scope", configuration.scopes.joined(separator: " "))
        ])
        let tokens = try await authorize(msa: msa, sessionID: signIn.sessionID, identity: signIn.identity)
        return try await finishSignIn(tokens: tokens, msa: msa, identity: signIn.identity, priorRefresh: nil)
    }

    public func restoreSession() async throws -> SignedInAccount? {
        // One refresh at a time, including actor reentrancy during network awaits.
        if let task = refreshTask { return try await task.value }
        let task = Task { try await self.performRestore() }
        refreshTask = task
        defer { refreshTask = nil }
        return try await task.value
    }

    public func signOut() async throws {
        generation &+= 1
        pending = nil
        refreshTask?.cancel()
        refreshTask = nil
        // Keep an empty item for this build, so the next launch has nothing older to ask about.
        let prefixes = Self.accountPrefixes(for: configuration), own = prefixes.current + vault.ownerTag
        stored = nil
        try saveVault(StoredVault())
        guard persistsCredentials else { return }
        for account in vault.accounts(withPrefix: prefixes.current) + vault.accounts(withPrefix: prefixes.legacy) where account != own {
            try vault.delete(account: account)
        }
    }

    private func performRestore() async throws -> SignedInAccount? {
        try startOperation(); defer { inProgress = false }
        try validateConfiguration()
        guard let saved = try loadVault().session else { return nil }
        if saved.account.expiresAt > Date().addingTimeInterval(60) { return saved.account }
        guard let refresh = saved.refreshToken, !refresh.isEmpty else { throw AuthError.signInRequired }
        let identity = try deviceIdentity()
        let msa: MicrosoftTokenReply = try await formRequest(stage: "Microsoft session renewal", values: [
            ("client_id", configuration.clientID), ("grant_type", "refresh_token"),
            ("refresh_token", refresh), ("scope", configuration.scopes.joined(separator: " "))
        ])
        let pkce = try PKCE.generate()
        let state = try secureRandomData(count: 32).base64URLString
        let device = try await deviceToken(identity)
        let session = try await sisuSession(device: device, pkce: pkce, state: state, identity: identity)
        let tokens = try await authorize(msa: msa, sessionID: session.id, identity: identity)
        return try await finishSignIn(tokens: tokens, msa: msa, identity: identity, priorRefresh: refresh)
    }

    private func startOperation() throws {
        guard !inProgress else { throw AuthError.busy }
        inProgress = true; operationGeneration = generation
    }

    private func checkOperation() throws {
        try Task.checkCancellation()
        guard operationGeneration == generation else { throw AuthError.cancelled }
    }

    /// Keychain account prefixes. Version 2 keeps the device key and session in one item per build
    /// signature ("auth.v2.<configuration>.<build>"); version 1 kept them in two shared items.
    static func accountPrefixes(for configuration: AuthConfiguration) -> (current: String, legacy: String) {
        // Namespace sessions by the complete configuration so an identity change
        // cannot reuse a different registration's credentials.
        let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
        let fingerprint = Data(SHA256.hash(data: (try? encoder.encode(configuration)) ?? Data()))
            .map { String(format: "%02x", $0) }.joined()
        return ("auth.v2." + fingerprint + ".", "auth.v1." + fingerprint + ".")
    }

    /// Reads this build's own item without asking. A build that has none yet reads the newest
    /// earlier item once (macOS asks), saves its own copy and retires the older items. Its later
    /// launches then never ask, whichever button was chosen.
    private func loadVault() throws -> StoredVault {
        if let current = stored { return current.vault }
        let prefixes = Self.accountPrefixes(for: configuration), own = prefixes.current + vault.ownerTag
        var sources = vault.accounts(withPrefix: prefixes.current)
        if sources.contains(own) {
            let data = try vault.readData(account: own)
            let value = data.flatMap { try? JSONDecoder().decode(StoredVault.self, from: $0) } ?? StoredVault()
            stored = (value, data)
            return value
        }
        var value = StoredVault()
        if let newest = sources.first {
            value = try vault.readData(account: newest).flatMap { try? JSONDecoder().decode(StoredVault.self, from: $0) } ?? StoredVault()
        } else {
            sources = vault.accounts(withPrefix: prefixes.legacy)
            let decoder = JSONDecoder()
            if sources.contains(prefixes.legacy + "device"), let data = try vault.readData(account: prefixes.legacy + "device") {
                value.device = try? decoder.decode(StoredDevice.self, from: data)
            }
            if sources.contains(prefixes.legacy + "session"), let data = try vault.readData(account: prefixes.legacy + "session") {
                value.session = try? decoder.decode(StoredSession.self, from: data)
            }
        }
        stored = (value, nil)
        guard persistsCredentials, !sources.isEmpty else { return value }
        try saveVault(value)
        for account in sources { try? vault.delete(account: account) }
        return value
    }

    private func saveVault(_ value: StoredVault) throws {
        let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
        let data = try encoder.encode(value)
        if persistsCredentials, data != stored?.data {
            try vault.setData(data, account: Self.accountPrefixes(for: configuration).current + vault.ownerTag)
            stored = (value, data)
        } else { stored = (value, stored?.data) }
    }

    private func validateConfiguration() throws {
        let identifier = "^[A-Za-z0-9-]+$"
        guard !configuration.clientID.isEmpty, configuration.clientID.range(of: identifier, options: .regularExpression) != nil,
              !configuration.xboxTitleID.isEmpty, configuration.xboxTitleID.allSatisfy({ $0.isNumber }),
              !configuration.playFabTitleID.isEmpty,
              configuration.playFabTitleID.range(of: "^[A-Za-z0-9]+$", options: .regularExpression) != nil,
              !configuration.scopes.isEmpty, configuration.redirectURI.user == nil,
              configuration.redirectURI.password == nil, configuration.redirectURI.fragment == nil,
              configuration.redirectURI.query == nil else { throw AuthError.invalidConfiguration("registration fields") }
    }

    private func deviceIdentity() throws -> DeviceIdentity {
        var value = try loadVault()
        if let device = value.device {
            guard let key = try? P256.Signing.PrivateKey(rawRepresentation: device.privateKey),
                  UUID(uuidString: device.id) != nil else { throw AuthError.signInRequired }
            return DeviceIdentity(id: device.id, key: key)
        }
        guard persistsCredentials else { throw AuthError.signInRequired }
        let identity = DeviceIdentity(id: UUID().uuidString.lowercased(), key: P256.Signing.PrivateKey())
        value.device = StoredDevice(id: identity.id, privateKey: identity.key.rawRepresentation)
        try saveVault(value)
        return identity
    }

    private func deviceToken(_ identity: DeviceIdentity) async throws -> XboxTokenReply {
        try await signedRequest(stage: "Xbox device authentication",
            url: URL(string: "https://device.auth.xboxlive.com/device/authenticate")!, identity: identity,
            body: ["RelyingParty": "http://auth.xboxlive.com", "TokenType": "JWT", "Properties": [
                "AuthMethod": "ProofOfPossession", "Id": "{\(identity.id)}",
                "DeviceType": configuration.deviceType, "Version": configuration.deviceVersion,
                "ProofKey": XboxRequestSigner.publicJWK(for: identity.key)
            ]])
    }

    private func sisuSession(device: XboxTokenReply, pkce: PKCE, state: String,
                             identity: DeviceIdentity) async throws -> (id: String, redirect: String,
                                                                       propertyNames: [String], headerNames: [String]) {
        let body: [String: Any] = ["AppId": configuration.clientID, "TitleId": configuration.xboxTitleID,
            "RedirectUri": configuration.redirectURI.absoluteString, "DeviceToken": device.Token,
            "Sandbox": configuration.sandbox, "TokenType": "code", "Offers": configuration.scopes,
            "Query": ["code_challenge": pkce.challenge, "code_challenge_method": "S256", "state": state]]
        let stage = "Microsoft sign-in initiation"
        let response = try await signedResponse(stage: stage, url: URL(string: "https://sisu.xboxlive.com/authenticate")!,
                                                body: body, identity: identity)
        let value: SisuBeginReply = try decode(response, stage: stage)
        guard let id = response.headers.first(where: { $0.key.lowercased() == "x-sessionid" })?.value,
              !id.isEmpty, !value.MsaOauthRedirect.isEmpty else {
            throw AuthError.malformedResponse("Microsoft sign-in initiation")
        }
        return (id, value.MsaOauthRedirect, Array(response.json.object?.keys ?? Dictionary<String, JSONValue>().keys), Array(response.headers.keys))
    }

    private func authorize(msa: MicrosoftTokenReply, sessionID: String,
                            identity: DeviceIdentity) async throws -> SisuTokensReply {
        guard !msa.access_token.isEmpty, msa.expires_in > 0 else { throw AuthError.malformedResponse("Microsoft token exchange") }
        // A fresh token for the same key and UUID, with no rejection workaround.
        let device = try await deviceToken(identity)
        let reply: SisuTokensReply = try await signedRequest(stage: "Xbox user authorization",
            url: URL(string: "https://sisu.xboxlive.com/authorize")!, identity: identity, body: [
                "AccessToken": "d=" + msa.access_token, "AppId": configuration.clientID,
                "DeviceToken": device.Token, "Sandbox": configuration.sandbox,
                "UseModernGamertag": true, "SiteName": "user.auth.xboxlive.com",
                "RelyingParty": "http://xboxlive.com", "SessionId": sessionID,
                "ProofKey": XboxRequestSigner.publicJWK(for: identity.key)
            ])
        guard !reply.UserToken.Token.isEmpty, !reply.TitleToken.Token.isEmpty else {
            throw AuthError.malformedResponse("Xbox user authorization")
        }
        return SisuTokensReply(UserToken: reply.UserToken, TitleToken: reply.TitleToken, DeviceToken: device)
    }

    private func xsts(_ tokens: SisuTokensReply, relyingParty: String) async throws -> XboxTokenReply {
        guard let device = tokens.DeviceToken else { throw AuthError.malformedResponse("Xbox device authentication") }
        return try await jsonRequest(stage: "Xbox relying-party authorization",
            url: URL(string: "https://xsts.auth.xboxlive.com/xsts/authorize")!, body: [
                "RelyingParty": relyingParty, "TokenType": "JWT", "Properties": [
                    "UserTokens": [tokens.UserToken.Token], "DeviceToken": device.Token,
                    "TitleToken": tokens.TitleToken.Token, "SandboxId": configuration.sandbox
                ]], headers: ["x-xbl-contract-version": "1"])
    }

    private func finishSignIn(tokens: SisuTokensReply, msa: MicrosoftTokenReply,
                              identity: DeviceIdentity, priorRefresh: String?) async throws -> SignedInAccount {
        let xbox = try await xsts(tokens, relyingParty: "http://xboxlive.com")
        guard let claims = xbox.DisplayClaims?.xui, claims.count == 1, let xuid = claims[0].xid,
              !xuid.isEmpty, xuid.allSatisfy({ $0 >= "0" && $0 <= "9" }) else {
            throw AuthError.malformedResponse("Xbox account identity")
        }
        let gamertag: String
        if let tag = claims[0].gtg, !tag.isEmpty { gamertag = tag }
        else { gamertag = try await ownGamertag(xuid: xuid, token: xbox, identity: identity) }
        let playFabXbox = try await xsts(tokens, relyingParty: "rp://playfabapi.com/")
        if let otherXUID = playFabXbox.DisplayClaims?.xui?.first?.xid, otherXUID != xuid {
            throw AuthError.malformedResponse("PlayFab account identity")
        }
        let url = URL(string: "https://\(configuration.playFabTitleID.lowercased()).playfabapi.com/Client/LoginWithXbox")!
        let envelope: PlayFabLoginReply = try await jsonRequest(stage: "PlayFab sign-in", url: url, body: [
            "TitleId": configuration.playFabTitleID, "XboxToken": try formatted(playFabXbox), "CreateAccount": true
        ])
        guard envelope.code == 200, let login = envelope.data, !login.SessionTicket.isEmpty,
              !login.EntityToken.EntityToken.isEmpty, !login.EntityToken.Entity.Id.isEmpty,
              login.EntityToken.Entity.type == "title_player_account" else {
            throw AuthError.malformedResponse("PlayFab sign-in")
        }
        let expiry = min(try parseDate(login.EntityToken.TokenExpiration), try parseDate(playFabXbox.NotAfter))
        guard expiry > Date().addingTimeInterval(30) else { throw AuthError.malformedResponse("PlayFab session expiry") }
        let account = SignedInAccount(xuid: xuid, gamertag: gamertag, sessionTicket: login.SessionTicket,
            entityToken: login.EntityToken.EntityToken, entityId: login.EntityToken.Entity.Id, expiresAt: expiry)
        try checkOperation()
        var value = try loadVault()
        value.session = StoredSession(refreshToken: msa.refresh_token ?? priorRefresh, account: account)
        try saveVault(value)
        return account
    }

    private func ownGamertag(xuid: String, token: XboxTokenReply, identity: DeviceIdentity) async throws -> String {
        let url = URL(string: "https://profile.xboxlive.com/users/xuid(\(xuid))/profile/settings?settings=Gamertag")!
        let authorization = try formatted(token)
        let signature = try XboxRequestSigner.signatureHeader(url: url, method: "GET", authorization: authorization,
                                                               privateKey: identity.key)
        let response = try await send(stage: "Xbox gamertag", url: url, method: "GET", headers: ["Authorization": authorization,
            "Signature": signature, "x-xbl-contract-version": "3", "Accept": "application/json"])
        let profile: XboxProfileReply = try decode(response, stage: "Xbox gamertag")
        guard let user = profile.profileUsers.first(where: { $0.id == xuid }),
              let tag = user.settings.first(where: { $0.id == "Gamertag" })?.value, !tag.isEmpty else {
            throw AuthError.malformedResponse("Xbox gamertag")
        }
        return tag
    }

    private func formatted(_ token: XboxTokenReply) throws -> String {
        guard let claims = token.DisplayClaims?.xui, claims.count == 1, !claims[0].uhs.isEmpty, !token.Token.isEmpty else {
            throw AuthError.malformedResponse("Xbox relying-party authorization")
        }
        return "XBL3.0 x=\(claims[0].uhs);\(token.Token)"
    }

    private func signedResponse(stage: String, url: URL, body: [String: Any], identity: DeviceIdentity) async throws -> HTTPResponse {
        let data = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
        let signature = try XboxRequestSigner.signatureHeader(url: url, method: "POST", body: data, privateKey: identity.key)
        return try await send(stage: stage, url: url, method: "POST", headers: ["Content-Type": "application/json; charset=utf-8",
            "x-xbl-contract-version": "1", "Signature": signature, "Cache-Control": "no-store"], body: data)
    }
    private func signedRequest<T: Decodable>(stage: String, url: URL, identity: DeviceIdentity,
                                              body: [String: Any]) async throws -> T {
        try decode(try await signedResponse(stage: stage, url: url, body: body, identity: identity), stage: stage)
    }
    private func jsonRequest<T: Decodable>(stage: String, url: URL, body: [String: Any],
                                           headers: [String: String] = [:]) async throws -> T {
        let data = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
        var fields = headers; fields["Content-Type"] = "application/json"; fields["Accept"] = "application/json"
        return try decode(try await send(stage: stage, url: url, method: "POST", headers: fields, body: data), stage: stage)
    }
    private func formRequest<T: Decodable>(stage: String, values: [(String, String)]) async throws -> T {
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        let data = Data(values.map { key, value in
            key.addingPercentEncoding(withAllowedCharacters: allowed)! + "=" + value.addingPercentEncoding(withAllowedCharacters: allowed)!
        }.joined(separator: "&").utf8)
        return try decode(try await send(stage: stage, url: URL(string: "https://login.live.com/oauth20_token.srf")!, method: "POST",
            headers: ["Content-Type": "application/x-www-form-urlencoded"], body: data), stage: stage)
    }
    private func send(stage: String, url: URL, method: String, headers: [String: String], body: Data? = nil) async throws -> HTTPResponse {
        try checkOperation()
        let response: HTTPResponse
        do { response = try await http.send(url: url, method: method, headers: headers, body: body) }
        catch let refusal as HTTPStatusError {
            // Xbox names the reason for a refusal only in its XErr code, so keep it with the step that failed.
            guard let xerr = refusal.xerr else { throw refusal }
            throw AuthError.xboxRefused(stage: stage, status: refusal.status, xerr: xerr)
        }
        try checkOperation()
        return response
    }
    private func decode<T: Decodable>(_ response: HTTPResponse, stage: String) throws -> T {
        guard let value = try? JSONDecoder().decode(T.self, from: response.data) else { throw AuthError.malformedResponse(stage) }
        return value
    }
    private func parseDate(_ string: String) throws -> Date {
        let formatter = ISO8601DateFormatter(); formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: string) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        guard let date = formatter.date(from: string) else { throw AuthError.malformedResponse("Authentication token expiry") }
        return date
    }
}

private struct DeviceIdentity { let id: String; let key: P256.Signing.PrivateKey }
private struct StoredDevice: Codable { let id: String; let privateKey: Data }
private struct StoredSession: Codable { let refreshToken: String?; let account: SignedInAccount }
private struct StoredVault: Codable { var device: StoredDevice?; var session: StoredSession? }
private struct PendingSignIn {
    let challenge: SignInChallenge; let verifier: String; let sessionID: String
    let identity: DeviceIdentity; let createdAt: Date
}
private struct MicrosoftTokenReply: Decodable {
    let access_token: String; let refresh_token: String?; let expires_in: Double
}
private struct SisuBeginReply: Decodable { let MsaOauthRedirect: String }
private struct XboxClaim: Decodable { let uhs: String; let xid: String?; let gtg: String? }
private struct XboxClaims: Decodable { let xui: [XboxClaim]? }
private struct XboxTokenReply: Decodable {
    let Token: String; let NotAfter: String; let DisplayClaims: XboxClaims?
}
private struct SisuTokensReply: Decodable {
    let UserToken: XboxTokenReply; let TitleToken: XboxTokenReply; let DeviceToken: XboxTokenReply?
}
private struct PlayFabLoginReply: Decodable { let code: Int; let data: PlayFabLoginData? }
private struct PlayFabLoginData: Decodable { let SessionTicket: String; let EntityToken: PlayFabEntityToken }
private struct PlayFabEntityToken: Decodable {
    let EntityToken: String; let TokenExpiration: String; let Entity: PlayFabEntity
}
private struct PlayFabEntity: Decodable {
    let Id: String; let type: String
    private enum CodingKeys: String, CodingKey { case Id, type = "Type" }
}
private struct XboxProfileReply: Decodable { let profileUsers: [XboxProfileUser] }
private struct XboxProfileUser: Decodable { let id: String; let settings: [XboxProfileSetting] }
private struct XboxProfileSetting: Decodable { let id: String; let value: String }
