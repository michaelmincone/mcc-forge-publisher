import Foundation
import CryptoKit
import Security

public struct AuthConfiguration: Codable, Sendable, Equatable {
    public let clientID: String
    public let xboxTitleID: String
    public let redirectURI: URL
    public let scopes: [String]
    public let sandbox: String
    public let deviceType: String
    public let deviceVersion: String
    public let playFabTitleID: String

    public init(clientID: String, xboxTitleID: String, redirectURI: URL,
                scopes: [String] = ["xboxlive.signin", "offline_access"], sandbox: String = "RETAIL",
                deviceType: String = "Win32", deviceVersion: String = "10.0.19045",
                playFabTitleID: String = "EE38") {
        self.clientID = clientID; self.xboxTitleID = xboxTitleID; self.redirectURI = redirectURI
        self.scopes = scopes; self.sandbox = sandbox; self.deviceType = deviceType
        self.deviceVersion = deviceVersion; self.playFabTitleID = playFabTitleID
    }

    // Public HaloCache compatibility identifiers, not an application secret or
    // a claim of Microsoft/Halo approval. Refusal never triggers identity rotation.
    public static let mcc = AuthConfiguration(clientID: "000000004825fc1f", xboxTitleID: "1144039928",
        redirectURI: URL(string: "https://login.live.com/oauth20_desktop.srf")!)
}

public struct SignInChallenge: Sendable {
    public let url: URL
    public let state: String
    public let redirectURI: URL
    public init(url: URL, state: String, redirectURI: URL) {
        self.url = url; self.state = state; self.redirectURI = redirectURI
    }
}

public struct SignedInAccount: Codable, Sendable, Equatable {
    public let xuid: String
    public let gamertag: String
    public let sessionTicket: String
    public let entityToken: String
    public let entityId: String
    public let expiresAt: Date
    public init(xuid: String, gamertag: String, sessionTicket: String, entityToken: String,
                entityId: String, expiresAt: Date) {
        self.xuid = xuid; self.gamertag = gamertag; self.sessionTicket = sessionTicket
        self.entityToken = entityToken; self.entityId = entityId; self.expiresAt = expiresAt
    }
}

public enum AuthError: Error, LocalizedError, Sendable, Equatable {
    case busy, signInRequired, cancelled
    case invalidCallback(String), malformedResponse(String), invalidConfiguration(String)
    case authorizationDenied(String)
    case browserRedirectRejected(BrowserAuthorizationDiagnostic)
    /// An Xbox service refused a step and named the reason with an XErr code.
    case xboxRefused(stage: String, status: Int, xerr: UInt32)
    public var errorDescription: String? {
        switch self {
        case .busy: return "A sign-in operation is already in progress."
        case .signInRequired: return "Sign in with your Microsoft account to continue."
        case .cancelled: return "Sign-in was cancelled."
        case .invalidCallback(let reason): return "Microsoft sign-in callback was rejected: \(reason)."
        case .malformedResponse(let stage): return "\(stage) returned an incomplete or invalid authentication response."
        case .invalidConfiguration(let reason): return "Authentication configuration is invalid: \(reason)."
        case .authorizationDenied(let code): return "Microsoft declined authorization (\(code))."
        case .browserRedirectRejected: return "Microsoft returned an unsupported browser authorization redirect."
        case .xboxRefused(let stage, let status, let xerr):
            let code = "HTTP \(status), XErr \(xerr) / 0x" + String(xerr, radix: 16, uppercase: true)
            return "\(stage) was refused by Xbox (\(code))." + (Self.xboxReasons[xerr].map { " " + $0 } ?? "")
        }
    }

    /// Xbox account errors as listed by the public HaloCache client (research/public/halo-mcc-auth), and
    /// the codes MCC's own sign-in handles specially (investigation/research/sisu-xerr).
    static let xboxReasons: [UInt32: String] = [
        0x8015DC03: "Xbox says this account is banned or suspended.",
        0x8015DC05: "Xbox says this account is restricted. Check its Xbox privacy and family settings.",
        0x8015DC09: "This Microsoft account has no Xbox profile. Sign in once at xbox.com to create one.",
        0x8015DC0A: "This account has not accepted the current Xbox terms of use. Sign in at xbox.com, accept them, then sign in here again.",
        0x8015DC0B: "Xbox is not available in this account's country or region.",
        0x8015DC0C: "Xbox needs proof of age for this account. Sign in at xbox.com to complete it.",
        0x8015DC0D: "Xbox reports a play-time limit or age check on this account.",
        0x8015DC0E: "This is a child account. An adult must add it to a Microsoft family group.",
        // Xbox's single point of presence: one device per game. The app signs in as MCC.
        0x8015DC1E: "Your account is already playing MCC on another device. Fully quit MCC on your Xbox or PC (on Xbox, also close it in Quick Resume), then open this app again.",
        0x8015DC20: "Xbox rejected the Microsoft sign-in for this account.",
        0x8015DC23: "Xbox rejected the Microsoft sign-in for this account.",
        0x8015DC34: "Xbox rejected the Microsoft sign-in for this account.",
    ]
}

/// Safe diagnostic metadata only. Never stores URL query values, codes, or tokens.
public struct BrowserAuthorizationDiagnostic: Codable, Sendable, Equatable {
    public let scheme: String?
    public let host: String?
    public let path: String?
    public let queryParameterNames: [String]
    public let responsePropertyNames: [String]
    public let responseHeaderNames: [String]
    public init(redirect: String, responsePropertyNames: [String] = [], responseHeaderNames: [String] = []) {
        let url = URLComponents(string: redirect)
        self.scheme = url?.scheme
        self.host = url?.host
        self.path = url?.path
        self.queryParameterNames = Array(Set((url?.queryItems ?? []).map(\.name))).sorted()
        self.responsePropertyNames = responsePropertyNames.sorted()
        self.responseHeaderNames = responseHeaderNames.sorted()
    }
}

public struct PKCE: Sendable, Equatable {
    public let verifier: String
    public let challenge: String
    public init(verifier: String) throws {
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        guard (43...128).contains(verifier.utf8.count), verifier.unicodeScalars.allSatisfy(allowed.contains) else {
            throw AuthError.invalidConfiguration("PKCE verifier format")
        }
        self.verifier = verifier
        self.challenge = Data(SHA256.hash(data: Data(verifier.utf8))).base64URLString
    }
    public static func generate() throws -> PKCE { try PKCE(verifier: secureRandomData(count: 32).base64URLString) }
}

public enum OAuthCallback {
    public static func authorizationCode(from callback: URL, redirectURI: URL, expectedState: String) throws -> String {
        guard let actual = URLComponents(url: callback, resolvingAgainstBaseURL: false),
              let expected = URLComponents(url: redirectURI, resolvingAgainstBaseURL: false),
              actual.scheme == expected.scheme, actual.host == expected.host, actual.port == expected.port,
              actual.percentEncodedPath == expected.percentEncodedPath, actual.user == nil, actual.password == nil,
              actual.fragment == nil else { throw AuthError.invalidCallback("redirect URI mismatch") }
        let query = actual.queryItems ?? []
        for name in ["state", "code", "error"] {
            guard query.filter({ $0.name == name }).count <= 1 else {
                throw AuthError.invalidCallback("duplicate response parameters")
            }
        }
        guard let state = query.first(where: { $0.name == "state" })?.value,
              !expectedState.isEmpty, constantTimeEqual(Data(state.utf8), Data(expectedState.utf8)) else {
            throw AuthError.invalidCallback("state mismatch")
        }
        if let refusal = query.first(where: { $0.name == "error" }) {
            if refusal.value == "access_denied" { throw AuthError.cancelled }
            let value = refusal.value ?? "authorization_error"
            let safe = value.count <= 96 && value.range(of: "^[A-Za-z0-9_.-]+$", options: .regularExpression) != nil
                ? value : "authorization_error"
            throw AuthError.authorizationDenied(safe)
        }
        guard let code = query.first(where: { $0.name == "code" })?.value, !code.isEmpty else {
            throw AuthError.invalidCallback("authorization code missing")
        }
        return code
    }
}

func secureRandomData(count: Int) throws -> Data {
    var data = Data(count: count)
    let status = data.withUnsafeMutableBytes { buffer in
        SecRandomCopyBytes(kSecRandomDefault, count, buffer.baseAddress!)
    }
    guard status == errSecSuccess else { throw AuthError.invalidConfiguration("random generator unavailable") }
    return data
}

func constantTimeEqual(_ left: Data, _ right: Data) -> Bool {
    guard left.count == right.count else { return false }
    var difference: UInt8 = 0
    for (a, b) in zip(left, right) { difference |= a ^ b }
    return difference == 0
}

extension Data {
    var base64URLString: String {
        base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
}
