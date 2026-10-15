import Foundation
import CryptoKit

public enum XboxRequestSigner {
    public static func windowsFileTime(unixSeconds: TimeInterval) throws -> UInt64 {
        guard unixSeconds.isFinite, unixSeconds >= 0,
              unixSeconds <= Double(UInt64.max / 10_000_000 - 11_644_473_600) else {
            throw AuthError.invalidConfiguration("request signing timestamp")
        }
        return (UInt64(unixSeconds.rounded(.down)) + 11_644_473_600) * 10_000_000
    }

    public static func preimage(url: URL, method: String, authorization: String = "", body: Data = Data(),
                                unixSeconds: TimeInterval) throws -> Data {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              url.scheme == "https", url.user == nil, url.password == nil, components.fragment == nil else {
            throw AuthError.invalidConfiguration("request signing URL")
        }
        var path = components.percentEncodedPath.isEmpty ? "/" : components.percentEncodedPath
        if let query = components.percentEncodedQuery { path += "?" + query }
        let upperMethod = method.uppercased()
        for field in [upperMethod, path, authorization] {
            guard field.utf8.allSatisfy({ $0 >= 32 && $0 < 127 }) else {
                throw AuthError.invalidConfiguration("request signing header characters")
            }
        }
        var data = Data()
        data.appendBigEndian(UInt32(1)); data.append(0)
        data.appendBigEndian(try windowsFileTime(unixSeconds: unixSeconds)); data.append(0)
        for field in [upperMethod, path, authorization] { data.append(Data(field.utf8)); data.append(0) }
        data.append(body); data.append(0)
        return data
    }

    public static func signatureHeader(url: URL, method: String, authorization: String = "", body: Data = Data(),
                                       privateKey: P256.Signing.PrivateKey, now: Date = Date()) throws -> String {
        let seconds = now.timeIntervalSince1970
        let input = try preimage(url: url, method: method, authorization: authorization, body: body, unixSeconds: seconds)
        let signature = try privateKey.signature(for: input).rawRepresentation
        guard signature.count == 64 else { throw AuthError.invalidConfiguration("P-256 signature format") }
        var header = Data()
        header.appendBigEndian(UInt32(1)); header.appendBigEndian(try windowsFileTime(unixSeconds: seconds))
        header.append(signature)
        return header.base64EncodedString()
    }

    public static func publicJWK(for key: P256.Signing.PrivateKey) -> [String: String] {
        let coordinates = key.publicKey.x963Representation // 04 || 32-byte x || 32-byte y
        return ["kty": "EC", "crv": "P-256", "alg": "ES256", "use": "sig",
                "x": Data(coordinates[1..<33]).base64URLString,
                "y": Data(coordinates[33..<65]).base64URLString]
    }
}

private extension Data {
    mutating func appendBigEndian<T: FixedWidthInteger>(_ value: T) {
        var bigEndian = value.bigEndian
        Swift.withUnsafeBytes(of: &bigEndian) { append(contentsOf: $0) }
    }
}
