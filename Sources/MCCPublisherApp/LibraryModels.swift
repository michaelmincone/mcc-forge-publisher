import Foundation
import CryptoKit
import MCCPublisherCore

enum LibraryKindFilter: String, CaseIterable, Identifiable {
    case all = "All files", maps = "Maps", gametypes = "Gametypes"
    var id: String { rawValue }
    func includes(_ kind: VariantKind) -> Bool { self == .all || (self == .maps && kind == .map) || (self == .gametypes && kind == .gametype) }
}

enum TransferState: String {
    case ready = "Ready", working = "In progress", succeeded = "Complete", skipped = "Already uploaded", failed = "Failed", uncertain = "Needs checking", cancelled = "Cancelled"
    var symbol: String {
        switch self {
        case .ready: "circle"
        case .working: "arrow.triangle.2.circlepath"
        case .succeeded: "checkmark.circle.fill"
        case .skipped: "checkmark.circle"
        case .failed, .uncertain: "exclamationmark.circle.fill"
        case .cancelled: "minus.circle"
        }
    }
    var isWarning: Bool { self == .failed || self == .uncertain }
}

struct UploadQueueEntry: Identifiable {
    let id = UUID()
    let sourceURL: URL
    let variant: ReachVariantDocument?
    let coreSHA256: String?
    var state: TransferState = .ready
    var detail = "Ready to upload"
    var title: String { variant?.title ?? sourceURL.lastPathComponent }
    var completedAccountXUID: String?
    var lastAttemptScope: String?

    init(url: URL) {
        sourceURL = url
        do {
            let loaded = try ReachVariantDocument.load(from: url)
            variant = loaded
            coreSHA256 = SHA256.hash(data: Data(loaded.bytes.prefix(loaded.embeddedLength))).map { String(format: "%02x", $0) }.joined()
        } catch {
            variant = nil; coreSHA256 = nil
            state = .failed; detail = error.localizedDescription
        }
    }
}

struct LibraryTransferResult: Identifiable {
    let id = UUID()
    let title: String
    let state: TransferState
    let detail: String
}

enum LibrarySearch {
    static func matches(_ item: FileShareItem, query: String, filter: LibraryKindFilter) -> Bool {
        guard filter.includes(item.kind) else { return false }
        return item.matches(search: query)
    }
}
