import Foundation
import CryptoKit

public struct PublicationUploadError: LocalizedError, Sendable {
    public enum Outcome: Sendable { case refused, uncertain }
    public let outcome: Outcome
    public let message: String
    public var errorDescription: String? { message }
}

public struct PublisherService: Sendable {
    public let http: HTTPClient
    public init(http: HTTPClient = HTTPClient()) { self.http = http }

    public func checkPermission(credentials: SignedInAccount, services: MCCServiceConfiguration) async throws {
        try MCCServiceConfiguration.validate(services.permission)
        let response = try await http.send(url: services.permission, method: "POST",
            headers: ["x-auth-token": credentials.sessionTicket, "Accept": "application/json"])
        guard let allowed = response.json["isAllowed"].bool else {
            throw PublisherError.protocolError("MCC did not return an upload-permission decision.")
        }
        guard allowed else {
            throw PublisherError.service("MCC did not permit this account to upload. Check your File Share and account restrictions in MCC.")
        }
    }

    // Deliberately never retries PUT automatically: a lost response can follow a successful publication.
    public func upload(plan: UploadPlan, credentials: SignedInAccount, services: MCCServiceConfiguration) async throws -> PublicationReceipt {
        try MCCServiceConfiguration.validate(services.upload)
        try await checkPermission(credentials: credentials, services: services)
        let request = try plan.request(credentials: credentials, services: services)
        let response: HTTPResponse
        do {
            response = try await http.send(url: services.upload, method: "PUT", headers: request.headers,
                body: request.body, allowsRedirects: false)
        } catch let error as HTTPStatusError where (400..<500).contains(error.status) && error.status != 408 {
            throw PublicationUploadError(outcome: .refused, message: "MCC refused the file upload (HTTP \(error.status)).")
        } catch {
            throw PublicationUploadError(outcome: .uncertain,
                message: "The upload reply was lost or unreadable. Refresh Shared Files before trying again; MCC may have accepted the file.")
        }
        let result = response.json["result"].string
        guard result == "success", let id = response.json["fileId"].string, !id.isEmpty else {
            if result == "deniedUpload" { throw PublicationUploadError(outcome: .refused, message: "MCC denied the file upload.") }
            if result == "signatureNotValid" { throw PublicationUploadError(outcome: .refused, message: "MCC rejected the file's provenance metadata. It was not published.") }
            throw PublicationUploadError(outcome: .uncertain,
                message: "MCC returned an unrecognized upload result. Refresh Shared Files before trying again; the request will not be repeated automatically.")
        }
        // Publish success is established by MCC's explicit result, not an HTTP 200 alone.
        let payloadHash = SHA256.hash(data: plan.payload).map { String(format: "%02x", $0) }.joined()
        return PublicationReceipt(itemID: id, title: plan.title, publishedAt: Date(), downloadVerified: false, fileSHA256: payloadHash)
    }

    public func verifyDownload(receipt: PublicationReceipt, credentials: SignedInAccount, services: MCCServiceConfiguration) async throws -> PublicationReceipt {
        try MCCServiceConfiguration.validate(services.itemLookup)
        let response = try await http.send(url: services.itemLookup, method: "POST",
            headers: ["X-EntityToken": credentials.entityToken, "Content-Type": "application/json"],
            body: JSONValue.object(["ItemId": .string(receipt.itemID)]).encoded())
        let item = response.json["Item"].object != nil ? response.json["Item"] : response.json["data"]["Item"]
        let contents = item["Contents"].array ?? []
        let content = contents.first(where: { $0["Type"].string == "data" }) ?? contents.first(where: { $0["Url"].string != nil })
        let raw = item["DownloadUrl"].string ?? content?["Url"].string ?? content?["DownloadUrl"].string
        guard let raw,
              let url = URL(string: raw), url.scheme == "https", let host = url.host?.lowercased(),
              host.hasSuffix(".blob.core.windows.net") || host.hasSuffix(".prod.catalog.playfab.com") || host == "mcc-production.azurefd.net" else {
            throw PublisherError.protocolError("The File Share item did not return a recognized download URL.")
        }
        // Blob URLs may contain scoped SAS credentials; neither URL nor response body is logged.
        let download = try await http.send(url: url, method: "GET")
        let hash = SHA256.hash(data: download.data).map { String(format: "%02x", $0) }.joined()
        guard download.data.count <= 16 * 1024 * 1024, hash == receipt.fileSHA256 else {
            throw PublisherError.protocolError("The downloaded map does not match the uploaded file. Publication is recorded, but validation failed.")
        }
        return PublicationReceipt(itemID: receipt.itemID, title: receipt.title, publishedAt: receipt.publishedAt, downloadVerified: true, fileSHA256: receipt.fileSHA256)
    }
}
