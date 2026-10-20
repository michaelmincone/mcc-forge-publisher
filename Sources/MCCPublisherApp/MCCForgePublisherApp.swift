import SwiftUI
import AppKit
import MCCPublisherCore

@main
struct MCCForgePublisherApp: App {
    @StateObject private var model = PublisherAppModel()
    var body: some Scene {
        WindowGroup("MCC Forge Publisher") {
            PublisherView(model: model)
                .frame(minWidth: 800, minHeight: 700)
                .task { await model.restore() }
                .onOpenURL { model.select($0) }
        }
        .windowStyle(.titleBar)
        .defaultSize(width: 900, height: 820)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Choose Map…") { model.chooseMap() }.keyboardShortcut("o")
                    .disabled(model.operationInProgress)
            }
            CommandGroup(after: .appInfo) {
                Button("Service Configuration…") { model.chooseConfiguration() }
                    .disabled(model.operationInProgress)
            }
        }
    }
}

struct PublisherView: View {
    @ObservedObject var model: PublisherAppModel
    private let green = Color(red: 0.47, green: 0.86, blue: 0.62)
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(alignment: .top, spacing: 16) {
                Image(systemName: "arrow.up.arrow.down")
                    .font(.system(size: 34)).foregroundStyle(green)
                    .padding(14).background(green.opacity(0.09), in: RoundedRectangle(cornerRadius: 16))
                VStack(alignment: .leading, spacing: 6) {
                    Text("MCC Forge Publisher").font(.system(size: 28, weight: .semibold))
                    Text("Publish Reach maps and download maps from your MCC File Share.")
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            HStack {
                VStack(alignment: .leading, spacing: 5) {
                    Text(model.account?.gamertag ?? "Microsoft account").font(.headline)
                    Text(model.account == nil ? "Sign in to your Xbox profile." : "Connected to MCC").foregroundStyle(.secondary)
                }
                Spacer()
                if model.account == nil {
                    Button("Sign in with Microsoft") { Task { await model.signIn() } }
                        .buttonStyle(.borderedProminent).tint(green).disabled(model.operationInProgress)
                } else {
                    if model.fileShareNeedsSignIn {
                        Button("Sign in again") { Task { await model.signIn() } }
                            .buttonStyle(.borderedProminent).tint(green).disabled(model.operationInProgress)
                    }
                    Button("Sign out") { Task { await model.signOut() } }.disabled(model.operationInProgress)
                }
            }.padding(18).background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 12))
            TabView {
                PublishMapView(model: model, green: green)
                    .tabItem { Label("Publish", systemImage: "square.and.arrow.up") }
                FileShareBrowserView(model: model, green: green)
                    .tabItem { Label("File Share", systemImage: "square.and.arrow.down") }
            }
        }.padding(26).preferredColorScheme(.dark)
    }
}

private struct PublishMapView: View {
    @ObservedObject var model: PublisherAppModel
    let green: Color
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                VStack(spacing: 14) {
                    Image(systemName: model.map == nil ? "square.and.arrow.down" : "checkmark.document")
                        .font(.system(size: 34, weight: .light)).foregroundStyle(model.map == nil ? .secondary : green)
                    Text(model.map?.title ?? "Drop a Reach map here").font(.title3.weight(.medium))
                    if let map = model.map {
                        Text(map.fileName + " · " + ByteCountFormatter.string(fromByteCount: Int64(map.bytes.count), countStyle: .file))
                            .font(.callout).foregroundStyle(.secondary)
                        if !map.description.isEmpty { Text(map.description).foregroundStyle(.secondary).lineLimit(3).multilineTextAlignment(.center) }
                    } else {
                        Text("Choose the .mvar file exported from Blender.").foregroundStyle(.secondary)
                    }
                    Button(model.map == nil ? "Choose Map…" : "Choose a Different Map…") { model.chooseMap() }
                        .disabled(model.operationInProgress)
                }
                .frame(maxWidth: .infinity, minHeight: 200).padding(20)
                .background(green.opacity(0.035), in: RoundedRectangle(cornerRadius: 16))
                .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(green.opacity(0.28), style: StrokeStyle(lineWidth: 1, dash: model.map == nil ? [6] : [])))
                .onDrop(of: [.fileURL], isTargeted: nil) { providers in
                    guard !model.operationInProgress, let p = providers.first else { return false }
                    p.loadItem(forTypeIdentifier: "public.file-url", options: nil) { item, _ in
                        if let data = item as? Data, let url = URL(dataRepresentation: data, relativeTo: nil) {
                            Task { @MainActor in model.select(url) }
                        } else if let url = item as? URL { Task { @MainActor in model.select(url) } }
                    }
                    return true
                }
                HStack(spacing: 12) {
                    if model.busy { ProgressView().controlSize(.small) }
                    Text(model.message).foregroundStyle(model.error ? Color.orange : .secondary).textSelection(.enabled)
                    Spacer(minLength: 0)
                }.frame(minHeight: 40, alignment: .leading)
                if let receipt = model.receipt {
                    HStack {
                        Label(receipt.downloadVerified ? "Stored map bytes verified" : "Published to MCC File Share", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(green)
                        Spacer()
                        Button("Check Download") { Task { await model.checkDownload() } }
                            .disabled(model.operationInProgress || model.account == nil)
                    }
                    Text("The stored file check does not confirm Xbox compatibility. Check the download in MCC on Xbox.")
                        .font(.callout).foregroundStyle(.secondary)
                }
                HStack {
                    Text("Your map file stays unchanged.").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Upload to File Share") { Task { await model.publish() } }
                        .buttonStyle(.borderedProminent).tint(green).controlSize(.large)
                        .disabled(model.operationInProgress || model.map == nil || model.account == nil || model.receipt != nil || !model.historyAvailable)
                }
            }.padding(20)
        }
    }
}

private struct FileShareBrowserView: View {
    @ObservedObject var model: PublisherAppModel
    let green: Color
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Your map variants").font(.title3.weight(.semibold))
                    Text("Includes maps uploaded through MCC and other tools.")
                        .font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    Task { await model.refreshFileShare() }
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .disabled(model.operationInProgress || model.account == nil)
            }
            if let deletionMessage = model.fileShareDeletionMessage {
                Label(deletionMessage, systemImage: model.fileShareDeletionHasWarning ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                    .foregroundStyle(model.fileShareDeletionHasWarning ? Color.orange : green)
                    .font(.callout).textSelection(.enabled)
                    .padding(12).frame(maxWidth: .infinity, alignment: .leading)
                    .background((model.fileShareDeletionHasWarning ? Color.orange : green).opacity(0.1), in: RoundedRectangle(cornerRadius: 10))
            }
            if let journalMessage = model.fileShareDeletionJournalMessage {
                Label(journalMessage, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange).font(.callout).textSelection(.enabled)
                    .padding(12).frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 10))
            }
            if let warning = model.fileShareWarning {
                Label(warning, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange).font(.callout).textSelection(.enabled)
                    .padding(12).frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 10))
            }
            HStack(alignment: .top, spacing: 10) {
                if model.fileShareBusy { ProgressView().controlSize(.small) }
                Text(model.fileShareMessage)
                    .foregroundStyle(model.fileShareError ? Color.orange : .secondary)
                    .textSelection(.enabled)
            }.font(.callout).frame(maxWidth: .infinity, alignment: .leading)
            if model.account == nil {
                ContentUnavailableView("Sign in to view your File Share", systemImage: "person.crop.circle", description: Text("Use Sign in with Microsoft above to connect your Xbox profile."))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if model.fileShareItems.isEmpty {
                emptyState
            } else {
                HSplitView {
                    List(model.fileShareItems, selection: $model.fileShareSelectionID) { item in
                        FileShareItemRow(item: item).tag(item.id)
                    }
                    .listStyle(.inset)
                    .frame(minWidth: 270, idealWidth: 330)
                    .accessibilityLabel("Map variants on your File Share")
                    FileShareItemDetail(model: model, green: green)
                        .frame(minWidth: 270, maxWidth: .infinity, maxHeight: .infinity)
                }
                .frame(minHeight: 220)
            }
            if let savedURL = model.fileShareSavedURL {
                VStack(alignment: .leading, spacing: 7) {
                    HStack {
                        Label("Saved \(model.fileShareSavedTitle ?? "map variant")", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(green).font(.headline)
                        Spacer()
                        Button("Reveal in Finder") { model.revealDownloadedFile() }
                    }
                    Text(savedURL.path).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                    if let sha256 = model.fileShareSavedSHA256 {
                        DisclosureGroup("SHA-256") {
                            Text(sha256).font(.caption.monospaced()).textSelection(.enabled)
                        }.font(.caption).foregroundStyle(.secondary)
                    }
                }.padding(12).background(green.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
            }
        }.padding(20)
    }

    @ViewBuilder private var emptyState: some View {
        if model.fileShareLoading {
            ContentUnavailableView("Loading File Share", systemImage: "arrow.down.circle", description: Text("Fetching your account’s map variants…"))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if model.fileShareError {
            ContentUnavailableView("File Share unavailable", systemImage: "wifi.exclamationmark", description: Text("Refresh to try loading your File Share again."))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if model.fileShareHasLoaded && model.fileShareWarning == nil {
            ContentUnavailableView("No map variants found", systemImage: "map", description: Text("This account’s File Share contains no map variants."))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ContentUnavailableView(model.fileShareWarning == nil ? "Browse your File Share" : "No map variants loaded yet", systemImage: "tray.and.arrow.down", description: Text("Refresh to load the map variants on this account."))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

private struct FileShareItemRow: View {
    let item: FileShareItem
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(item.title).font(.headline).lineLimit(2).help(item.title)
            if let game = item.game { Text(game).font(.callout).foregroundStyle(.secondary) }
            HStack {
                if let baseMap = item.baseMap { Text(baseMap).lineLimit(1) }
                Spacer(minLength: 4)
                if let size = item.fileSize {
                    Text(ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file))
                }
            }.font(.caption).foregroundStyle(.secondary)
            Text(item.id).font(.caption2.monospaced()).foregroundStyle(.tertiary).lineLimit(1)
        }.padding(.vertical, 6)
    }
}

private struct FileShareItemDetail: View {
    @ObservedObject var model: PublisherAppModel
    let green: Color
    var body: some View {
        if let item = model.selectedFileShareItem {
            VStack(alignment: .leading, spacing: 16) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        Text(item.title).font(.title2.weight(.semibold)).textSelection(.enabled)
                        Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 9) {
                            if let game = item.game { detailRow("Game", game) }
                            if let baseMap = item.baseMap { detailRow("Base map", baseMap) }
                            if let size = item.fileSize {
                                detailRow("Size", ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file))
                            }
                            if let modifiedAt = item.modifiedAt {
                                detailRow("Modified", modifiedAt.formatted(date: .abbreviated, time: .shortened))
                            }
                        }.font(.callout)
                        if !item.description.isEmpty {
                            Text(item.description).font(.body).textSelection(.enabled)
                        }
                        VStack(alignment: .leading, spacing: 5) {
                            Text("Item ID").font(.caption).foregroundStyle(.secondary)
                            Text(item.id).font(.caption.monospaced()).textSelection(.enabled)
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }
                Text("Saves a local .mvar file. In-game compatibility must be checked in MCC.")
                    .font(.caption).foregroundStyle(.secondary)
                Button {
                    Task { await model.downloadSelectedFileShareItem() }
                } label: {
                    Label("Download…", systemImage: "square.and.arrow.down")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent).tint(green).controlSize(.large)
                .disabled(model.operationInProgress || model.account == nil)
                Button(role: .destructive) {
                    Task { await model.deleteSelectedFileShareItem() }
                } label: {
                    Label("Delete from File Share…", systemImage: "trash")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered).tint(.red)
                .disabled(model.operationInProgress || model.account == nil || !model.fileShareDeletionJournalAvailable)
            }.padding(.leading, 18).padding(.vertical, 8)
        } else {
            ContentUnavailableView("Select a map variant", systemImage: "map", description: Text("Choose a map to view its details and download it."))
        }
    }
    private func detailRow(_ title: String, _ value: String) -> some View {
        GridRow {
            Text(title).foregroundStyle(.secondary)
            Text(value).textSelection(.enabled)
        }
    }
}
