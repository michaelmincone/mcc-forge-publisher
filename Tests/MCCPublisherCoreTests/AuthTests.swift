import Foundation
import CryptoKit

#if canImport(XCTest) && !AUTH_STANDALONE_TESTS && !AUTH_BEGIN_PROBE
import XCTest
@testable import MCCPublisherCore

final class AuthTests: XCTestCase {
    func testPKCEPublishedRFCVector() throws {
        let pkce = try PKCE(verifier: "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk")
        XCTAssertEqual(pkce.challenge, "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
        XCTAssertThrowsError(try PKCE(verifier: "too-short"))
        XCTAssertThrowsError(try PKCE(verifier: String(repeating: "é", count: 43)))
    }

    func testRandomPKCEHasRequiredLengthAndNewEntropy() throws {
        let a = try PKCE.generate(), b = try PKCE.generate()
        XCTAssertEqual(a.verifier.utf8.count, 43)
        XCTAssertEqual(a.challenge.utf8.count, 43)
        XCTAssertNotEqual(a.verifier, b.verifier)
    }

    func testSigningPreimagePublishedNonsecretFixture() throws {
        let data = try XboxRequestSigner.preimage(url: URL(string: "https://device.auth.xboxlive.com/device/authenticate")!,
            method: "POST", body: Data("{}".utf8), unixSeconds: 0)
        XCTAssertEqual(data.map { String(format: "%02x", $0) }.joined(),
            "0000000100019db1ded53e800000504f5354002f6465766963652f61757468656e74696361746500007b7d00")
        XCTAssertEqual(try XboxRequestSigner.windowsFileTime(unixSeconds: 0), 116_444_736_000_000_000)
    }

    func testSignatureIsRawP256AndAuthenticatesExactTransmittedBytes() throws {
        let key = P256.Signing.PrivateKey()
        let url = URL(string: "https://device.auth.xboxlive.com/device/authenticate?q=one%20two")!
        let body = Data("{\"text\":\"café\"}".utf8)
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let header = try XboxRequestSigner.signatureHeader(url: url, method: "POST", body: body, privateKey: key, now: now)
        let bytes = try XCTUnwrap(Data(base64Encoded: header))
        XCTAssertEqual(bytes.count, 76)
        let signature = try P256.Signing.ECDSASignature(rawRepresentation: bytes.dropFirst(12))
        let input = try XboxRequestSigner.preimage(url: url, method: "POST", body: body, unixSeconds: now.timeIntervalSince1970)
        XCTAssertTrue(key.publicKey.isValidSignature(signature, for: input))
        let changed = try XboxRequestSigner.preimage(url: url, method: "POST", body: Data("{}".utf8), unixSeconds: now.timeIntervalSince1970)
        XCTAssertFalse(key.publicKey.isValidSignature(signature, for: changed))
        let jwk = XboxRequestSigner.publicJWK(for: key)
        XCTAssertEqual(jwk["kty"], "EC"); XCTAssertEqual(jwk["crv"], "P-256")
        XCTAssertEqual(jwk["x"]?.count, 43); XCTAssertEqual(jwk["y"]?.count, 43)
        XCTAssertNil(jwk["d"])
    }

    func testCallbackRequiresExactURIStateAndSingleCode() throws {
        let redirect = URL(string: "https://login.live.com/oauth20_desktop.srf")!
        let good = URL(string: redirect.absoluteString + "?code=NONSECRET_TEST_CODE&state=expected")!
        XCTAssertEqual(try OAuthCallback.authorizationCode(from: good, redirectURI: redirect, expectedState: "expected"), "NONSECRET_TEST_CODE")
        let bad = [
            "https://attacker.example/oauth20_desktop.srf?code=x&state=expected",
            "https://login.live.com/oauth20_desktop.srf/extra?code=x&state=expected",
            "https://login.live.com/oauth20_desktop.srf?code=x&state=wrong",
            "https://login.live.com/oauth20_desktop.srf?code=x&state=expected&state=expected",
            "https://login.live.com/oauth20_desktop.srf?code=x&code=y&state=expected",
            "https://login.live.com/oauth20_desktop.srf?code=x",
            "https://login.live.com/oauth20_desktop.srf?code=x&state=expected#fragment",
        ]
        for value in bad {
            XCTAssertThrowsError(try OAuthCallback.authorizationCode(from: URL(string: value)!, redirectURI: redirect, expectedState: "expected"))
        }
    }

    func testNoPendingChallengeRejectsBeforeNetworkOrKeychainAccess() async {
        let service = AuthService()
        do {
            _ = try await service.completeSignIn(callback: URL(string: "https://login.live.com/oauth20_desktop.srf?code=x&state=x")!)
            XCTFail("An unsolicited callback must be rejected")
        } catch {
            XCTAssertEqual(error as? AuthError, .invalidCallback("no pending sign-in"))
        }
    }

    func testEachBuildAsksOnceAndToolsNeverWrite() async throws {
        try await VaultScenario.run { XCTAssertTrue($0, $1) }
    }

    func testXboxRefusalKeepsItsErrorCodeAndStep() async throws {
        try await XboxRefusalScenario.run { XCTAssertTrue($0, $1) }
    }
}
#endif

#if (canImport(XCTest) && !AUTH_STANDALONE_TESTS && !AUTH_BEGIN_PROBE) || AUTH_STANDALONE_TESTS
/// An in-memory keychain that behaves like macOS for this app: the build that created an item
/// reads it freely, any other build's read needs the user's approval (counted), and only the
/// creator can delete it.
final class MemoryKeychain: @unchecked Sendable {
    let lock = NSLock()
    var items: [String: (data: Data, owner: String, created: Int)] = [:]
    var clock = 0, approvals = 0, writes = 0
}

struct MemoryVault: CredentialVault {
    let keychain: MemoryKeychain
    let ownerTag: String
    func accounts(withPrefix prefix: String) -> [String] {
        keychain.lock.withLock { keychain.items.filter { $0.key.hasPrefix(prefix) }.sorted { $0.value.created > $1.value.created }.map(\.key) }
    }
    func readData(account: String) throws -> Data? {
        keychain.lock.withLock {
            guard let item = keychain.items[account] else { return nil }
            if item.owner != ownerTag { keychain.approvals += 1 }
            return item.data
        }
    }
    func setData(_ data: Data, account: String) throws {
        keychain.lock.withLock {
            keychain.writes += 1
            if keychain.items[account] != nil { keychain.items[account]!.data = data }
            else { keychain.clock += 1; keychain.items[account] = (data, ownerTag, keychain.clock) }
        }
    }
    func delete(account: String) throws {
        keychain.lock.withLock {
            guard let item = keychain.items[account] else { return }
            if item.owner == ownerTag { keychain.items[account] = nil } else { keychain.items[account]!.data = Data("{}".utf8) }
        }
    }
}

enum VaultScenario {
    private struct LegacyDevice: Codable { let id: String; let privateKey: Data }
    private struct LegacySession: Codable { let refreshToken: String?; let account: SignedInAccount }

    static func run(_ check: (Bool, String) throws -> Void) async throws {
        let keychain = MemoryKeychain(), prefixes = AuthService.accountPrefixes(for: .mcc)
        let account = SignedInAccount(xuid: "2535400000000000", gamertag: "Tester", sessionTicket: "NONSECRET",
                                      entityToken: "NONSECRET", entityId: "NONSECRET", expiresAt: Date().addingTimeInterval(3600))
        func service(_ build: String, persists: Bool = true) -> AuthService {
            AuthService(vault: MemoryVault(keychain: keychain, ownerTag: build), persistsCredentials: persists)
        }
        let old = MemoryVault(keychain: keychain, ownerTag: "old")
        try old.setData(JSONEncoder().encode(LegacyDevice(id: UUID().uuidString.lowercased(),
            privateKey: P256.Signing.PrivateKey().rawRepresentation)), account: prefixes.legacy + "device")
        try old.setData(JSONEncoder().encode(LegacySession(refreshToken: "NONSECRET", account: account)), account: prefixes.legacy + "session")

        let tool = try await service("tool", persists: false).restoreSession()
        try check(tool == account && keychain.writes == 2, "A read-only tool must use the saved sign-in without writing")

        var approvals = keychain.approvals
        let migrating = service("new")
        try check(await migrating.savedSignInNeedsApproval(), "A new build must expect approval")
        try check(try await migrating.restoreSession() == account, "Version 1 sign-in restored")
        try check(keychain.approvals - approvals == 2, "Version 1 migration reads each old item once")
        try check(keychain.items[prefixes.current + "new"] != nil, "The new build saves its own item")
        try check(keychain.items[prefixes.legacy + "session"]?.data == Data("{}".utf8), "Old items are cleared")

        approvals = keychain.approvals
        let relaunched = service("new")
        try check(await !relaunched.savedSignInNeedsApproval(), "A relaunch must not expect approval")
        try check(try await relaunched.restoreSession() == account && keychain.approvals == approvals, "A relaunch never asks")

        let updated = service("newer")
        try check(try await updated.restoreSession() == account && keychain.approvals == approvals + 1, "An update asks once")
        try check(keychain.items[prefixes.current + "new"]?.data == Data("{}".utf8), "The update clears the older build's item")
        approvals = keychain.approvals
        try check(try await service("newer").restoreSession() == account && keychain.approvals == approvals, "The updated build never asks again")

        try await updated.signOut()
        try check(try await service("newer").restoreSession() == nil && keychain.approvals == approvals, "Signed out without asking")
        try check(try await service("next").restoreSession() == nil && keychain.approvals == approvals + 1, "After sign-out an update asks at most once")
        approvals = keychain.approvals
        try check(try await service("next").restoreSession() == nil && keychain.approvals == approvals, "Then it stays quiet")
    }
}
/// Answers each auth endpoint locally; SISU authorize refuses with an x-err header and an empty body, as Xbox does.
final class RefusingXbox: URLProtocol {
    nonisolated(unsafe) static var refusal = "2148916234"
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let url = request.url!, path = url.path
        var status = 200, headers = ["Content-Type": "application/json"], body = Data()
        let later = ISO8601DateFormatter().string(from: Date().addingTimeInterval(3600))
        switch (url.host ?? "", path) {
        case ("login.live.com", _):
            body = Data(#"{"access_token":"NONSECRET","refresh_token":"NONSECRET","expires_in":3600}"#.utf8)
        case ("device.auth.xboxlive.com", _):
            body = Data(#"{"Token":"NONSECRET","NotAfter":"\#(later)"}"#.utf8)
        case ("sisu.xboxlive.com", "/authenticate"):
            headers["X-SessionId"] = "NONSECRET"
            body = Data(#"{"MsaOauthRedirect":"https://sisu.xboxlive.com/client/v68/x/view/splash.html"}"#.utf8)
        default:
            status = 401; headers = ["x-err": Self.refusal]
        }
        let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

enum XboxRefusalScenario {
    private struct Device: Codable { let id: String; let privateKey: Data }
    private struct Session: Codable { let refreshToken: String?; let account: SignedInAccount }
    private struct Vault: Codable { let device: Device; let session: Session }

    static func run(_ check: (Bool, String) throws -> Void) async throws {
        try check(HTTPStatusError.xboxCode("2148916234") == 0x8015DC0A && HTTPStatusError.xboxCode("0x8015DC0A") == 0x8015DC0A
                  && HTTPStatusError.xboxCode("ban") == nil, "x-err values parse as decimal or 0x hexadecimal")
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [RefusingXbox.self]
        let http = HTTPClient(session: URLSession(configuration: config))
        do {
            _ = try await http.send(url: URL(string: "https://sisu.xboxlive.com/authorize")!, method: "POST")
            try check(false, "A 401 must throw")
        } catch let error as HTTPStatusError {
            try check(error == HTTPStatusError(host: "sisu.xboxlive.com", status: 401, xerr: 0x8015DC0A), "The x-err header is kept")
            try check(error.localizedDescription == "sisu.xboxlive.com returned HTTP 401 (XErr 2148916234).", "Plain HTTP refusal text")
        }

        // An expired saved session renews through SISU, so the refusal surfaces from restore without a browser.
        let keychain = MemoryKeychain(), vault = MemoryVault(keychain: keychain, ownerTag: "build")
        let expired = SignedInAccount(xuid: "2535400000000000", gamertag: "Tester", sessionTicket: "NONSECRET",
                                      entityToken: "NONSECRET", entityId: "NONSECRET", expiresAt: Date().addingTimeInterval(-60))
        let saved = Vault(device: Device(id: UUID().uuidString.lowercased(), privateKey: P256.Signing.PrivateKey().rawRepresentation),
                          session: Session(refreshToken: "NONSECRET", account: expired))
        try vault.setData(JSONEncoder().encode(saved), account: AuthService.accountPrefixes(for: .mcc).current + "build")
        do {
            _ = try await AuthService(http: http, vault: vault).restoreSession()
            try check(false, "Renewal must fail when SISU authorize refuses")
        } catch let error as AuthError {
            try check(error == .xboxRefused(stage: "Xbox user authorization", status: 401, xerr: 0x8015DC0A), "The refusal names the SISU authorize step")
            try check(error.localizedDescription.contains("XErr 2148916234 / 0x8015DC0A") && error.localizedDescription.contains("terms of use"),
                      "The refusal shows its code and the known reason")
        }
        RefusingXbox.refusal = "2148916254"
        do { _ = try await AuthService(http: http, vault: vault).restoreSession() } catch let error as AuthError {
            try check(error.localizedDescription.contains("0x8015DC1E") && error.localizedDescription.contains("another device"),
                      "Game-in-use refusal tells the user to quit MCC elsewhere")
        }
        RefusingXbox.refusal = "4294967295"
        do { _ = try await AuthService(http: http, vault: vault).restoreSession() } catch let error as AuthError {
            try check(error.localizedDescription == "Xbox user authorization was refused by Xbox (HTTP 401, XErr 4294967295 / 0xFFFFFFFF).",
                      "An unlisted code is still shown")
        }
        RefusingXbox.refusal = "2148916234"
    }
}
#endif

#if AUTH_BEGIN_PROBE
@main
struct AuthBeginDiagnosticProbe {
    static func main() async throws {
        let vault = KeychainStore(service: "org.mjolnir.MCCForgePublisher.AuthRedirectDiagnostic")
        let service = AuthService(vault: vault)
        do {
            let challenge = try await service.beginSignIn()
            let diagnostic = BrowserAuthorizationDiagnostic(redirect: challenge.url.absoluteString)
            print(String(decoding: try JSONEncoder().encode(diagnostic), as: UTF8.self))
            try await service.signOut()
        } catch let error as AuthError {
            if case .browserRedirectRejected(let diagnostic) = error {
                print(String(decoding: try JSONEncoder().encode(diagnostic), as: UTF8.self))
                try await service.signOut()
            } else { throw error }
        }
    }
}
#endif

#if AUTH_STANDALONE_TESTS
@main
struct AuthStandaloneTests {
    enum Failure: Error { case assertion(String) }
    static func check(_ value: @autoclosure () -> Bool, _ message: String) throws {
        if !value() { throw Failure.assertion(message) }
    }
    static func rejects(_ work: () throws -> Void, _ message: String) throws {
        do { try work() } catch { return }
        throw Failure.assertion(message)
    }
    static func main() async throws {
        let pkce = try PKCE(verifier: "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk")
        try check(pkce.challenge == "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM", "RFC 7636 PKCE vector")
        try rejects({ _ = try PKCE(verifier: "short") }, "Short PKCE verifier accepted")
        let random = try PKCE.generate()
        try check(random.verifier.count == 43 && random.challenge.count == 43, "PKCE entropy encoding")
        let url = URL(string: "https://device.auth.xboxlive.com/device/authenticate")!
        let input = try XboxRequestSigner.preimage(url: url, method: "POST", body: Data("{}".utf8), unixSeconds: 0)
        try check(input.map { String(format: "%02x", $0) }.joined() ==
            "0000000100019db1ded53e800000504f5354002f6465766963652f61757468656e74696361746500007b7d00", "Xbox unsigned preimage fixture")
        let queryURL = URL(string: "https://device.auth.xboxlive.com/device/authenticate?q=one%20two")!
        let queried = try XboxRequestSigner.preimage(url: queryURL, method: "GET", authorization: "NONSECRET", unixSeconds: 0)
        try check(queried.suffix(Data("/device/authenticate?q=one%20two\0NONSECRET\0\0".utf8).count)
            == Data("/device/authenticate?q=one%20two\0NONSECRET\0\0".utf8), "Query and authorization must be signed verbatim")
        let key = P256.Signing.PrivateKey(), now = Date(timeIntervalSince1970: 1_700_000_000)
        let body = Data("{\"text\":\"café\"}".utf8)
        let header = try XboxRequestSigner.signatureHeader(url: url, method: "POST", body: body, privateKey: key, now: now)
        guard let bytes = Data(base64Encoded: header) else { throw Failure.assertion("Signature Base64") }
        try check(bytes.count == 76, "Xbox raw header must be 76 bytes")
        let signature = try P256.Signing.ECDSASignature(rawRepresentation: bytes.dropFirst(12))
        let signed = try XboxRequestSigner.preimage(url: url, method: "POST", body: body, unixSeconds: now.timeIntervalSince1970)
        try check(key.publicKey.isValidSignature(signature, for: signed), "Raw P-256 signature did not verify")
        let modified = try XboxRequestSigner.preimage(url: url, method: "POST", body: Data("{}".utf8), unixSeconds: now.timeIntervalSince1970)
        try check(!key.publicKey.isValidSignature(signature, for: modified), "Signature accepted altered body")
        let jwk = XboxRequestSigner.publicJWK(for: key)
        try check(jwk["x"]?.count == 43 && jwk["y"]?.count == 43 && jwk["d"] == nil, "Public JWK coordinate encoding")
        let redirect = AuthConfiguration.mcc.redirectURI
        let good = URL(string: redirect.absoluteString + "?code=NONSECRET_TEST_CODE&state=expected")!
        let code = try OAuthCallback.authorizationCode(from: good, redirectURI: redirect, expectedState: "expected")
        try check(code == "NONSECRET_TEST_CODE", "Valid callback code")
        do {
            _ = try OAuthCallback.authorizationCode(from: URL(string: redirect.absoluteString + "?error=invalid_scope&state=expected")!, redirectURI: redirect, expectedState: "expected")
            throw Failure.assertion("Provider refusal accepted")
        } catch let error as AuthError {
            try check(error == .authorizationDenied("invalid_scope"), "Provider refusal classification")
        }
        for candidate in [
            "https://attacker.example/oauth20_desktop.srf?code=x&state=expected",
            redirect.absoluteString + "?code=x&state=wrong",
            redirect.absoluteString + "?code=x&state=expected&state=expected",
            redirect.absoluteString + "?code=x&code=y&state=expected",
            redirect.absoluteString + "?code=x",
            redirect.absoluteString + "?code=x&state=expected#fragment",
        ] {
            try rejects({ _ = try OAuthCallback.authorizationCode(from: URL(string: candidate)!, redirectURI: redirect, expectedState: "expected") }, "Invalid callback accepted")
        }
        let service = AuthService()
        do {
            _ = try await service.completeSignIn(callback: good)
            throw Failure.assertion("Unsolicited callback accepted")
        } catch let error as AuthError {
            try check(error == .invalidCallback("no pending sign-in"), "Unsolicited callback error")
        }
        try await VaultScenario.run { try check($0, $1) }
        try await XboxRefusalScenario.run { try check($0, $1) }
        print("Auth offline checks passed: PKCE, exact Xbox preimage, raw P-256 signature, JWK, callback rejection, one keychain approval per build, Xbox refusal codes; no live auth or Keychain access.")
    }
}
#endif
