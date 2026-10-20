import Foundation

public struct HTTPResponse: Sendable {
    public let data: Data
    public let status: Int
    public let headers: [String: String]
    public var json: JSONValue { (try? JSONDecoder().decode(JSONValue.self, from: data)) ?? .null }
}

// Authenticated requests must never follow a redirect to another service host.
private final class RedirectPolicy: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let allowsRedirects: Bool
    init(allowsRedirects: Bool = true) { self.allowsRedirects = allowsRedirects }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        guard allowsRedirects, let original = task.originalRequest?.url, let target = request.url,
              HTTPClient.permitsRedirect(from: original, to: target) else {
            completionHandler(nil); return
        }
        completionHandler(request)
    }
}

public struct HTTPClient: Sendable {
    private let session: URLSession
    public init(session: URLSession? = nil) {
        if let session { self.session = session }
        else {
            let c = URLSessionConfiguration.ephemeral
            c.timeoutIntervalForRequest = 60; c.timeoutIntervalForResource = 180
            c.httpCookieStorage = nil; c.urlCache = nil; c.requestCachePolicy = .reloadIgnoringLocalCacheData
            self.session = URLSession(configuration: c, delegate: RedirectPolicy(), delegateQueue: nil)
        }
    }
    public static func permitsRedirect(from original: URL, to target: URL) -> Bool {
        original.scheme == "https" && target.scheme == "https" &&
        original.host?.lowercased() == target.host?.lowercased() &&
        (original.port ?? 443) == (target.port ?? 443) &&
        target.user == nil && target.password == nil
    }
    public func send(url: URL, method: String, headers: [String: String] = [:], body: Data? = nil,
                     allowsRedirects: Bool = true) async throws -> HTTPResponse {
        guard url.scheme == "https", url.user == nil, url.password == nil else {
            throw PublisherError.protocolError("The service URL must use HTTPS without embedded credentials.")
        }
        var request = URLRequest(url: url); request.httpMethod = method; request.httpBody = body
        request.setValue("MjolnirPublisher/0.1 (macOS)", forHTTPHeaderField: "User-Agent")
        for (key, value) in headers {
            guard !key.utf8.contains(13), !key.utf8.contains(10), !value.utf8.contains(13), !value.utf8.contains(10) else {
                throw PublisherError.protocolError("A request header contains an invalid line break.")
            }
            request.setValue(value, forHTTPHeaderField: key)
        }
        // Destructive operations can prohibit even same-origin redirects, which
        // otherwise may replay a POST at a new endpoint after HTTP 307/308.
        let policy = RedirectPolicy(allowsRedirects: allowsRedirects)
        let (stream, response) = try await session.bytes(for: request, delegate: policy)
        let limit = 17 * 1024 * 1024
        guard response.expectedContentLength <= Int64(limit) else {
            throw PublisherError.service("The service response exceeds the allowed size.")
        }
        var data = Data()
        for try await byte in stream {
            guard data.count < limit else { throw PublisherError.service("The service response exceeds the allowed size.") }
            data.append(byte)
        }
        guard let response = response as? HTTPURLResponse else { throw PublisherError.service("The server returned no HTTP response.") }
        let fields = Dictionary(response.allHeaderFields.map { (String(describing: $0.key).lowercased(), String(describing: $0.value)) }, uniquingKeysWith: { _, b in b })
        let result = HTTPResponse(data: data, status: response.statusCode, headers: fields)
        guard (200..<300).contains(result.status) else {
            let code = result.json["error"].string ?? result.json["errorCode"].string
            // Server response bodies may contain credentials. Show only status and short error identifiers.
            let safe = code.flatMap { $0.count <= 96 && $0.range(of: "^[A-Za-z0-9_. -]+$", options: .regularExpression) != nil ? $0 : nil }
            // SISU refusals have an empty body and put Xbox's error code in the x-err header; XSTS puts it in the body.
            let xerr = result.headers["x-err"].flatMap(HTTPStatusError.xboxCode) ?? result.json["XErr"].number.flatMap { UInt32(exactly: $0) }
            throw HTTPStatusError(host: url.host ?? "Service", status: result.status, code: safe, xerr: xerr)
        }
        return result
    }
}

/// A non-success HTTP reply. Holds only the status and short error identifiers, never the body.
public struct HTTPStatusError: LocalizedError, Sendable, Equatable {
    public let host: String
    public let status: Int
    public let code: String?
    /// Xbox's numeric error code (XErr), when the service sent one.
    public let xerr: UInt32?
    public init(host: String, status: Int, code: String? = nil, xerr: UInt32? = nil) {
        self.host = host; self.status = status; self.code = code; self.xerr = xerr
    }
    public var errorDescription: String? {
        let details = [code, xerr.map { "XErr \($0)" }].compactMap { $0 }
        return "\(host) returned HTTP \(status)\(details.isEmpty ? "" : " (\(details.joined(separator: ", ")))")."
    }
    /// Parses an x-err header value: decimal, or hexadecimal with a 0x prefix.
    public static func xboxCode(_ raw: String) -> UInt32? {
        let value = raw.trimmingCharacters(in: .whitespaces)
        if value.lowercased().hasPrefix("0x") { return UInt32(value.dropFirst(2), radix: 16) }
        return UInt32(value)
    }
}
