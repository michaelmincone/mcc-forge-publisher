import SwiftUI
import AppKit
import MCCPublisherCore

@main
struct MCCForgePublisherApp: App {
    @StateObject private var model = PublisherAppModel()
    var body: some Scene {
        WindowGroup("MCC Forge Publisher") {
            PublisherView(model: model)
                .frame(minWidth: 980, minHeight: 650)
                .task { if !model.isPreview { await model.restore() } }
                .onOpenURL { model.select($0) }
        }
        .windowStyle(.titleBar)
        .defaultSize(width: 1150, height: 790)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Add Maps or Gametypes…") { model.chooseFiles() }.keyboardShortcut("o")
                    .disabled(model.libraryInteractionDisabled)
            }
            CommandGroup(after: .appInfo) {
                Button("Service Configuration…") { model.chooseConfiguration() }.disabled(model.operationInProgress)
            }
        }
    }
}

// Disambiguate the property wrapper from newer SDK State macros on Command Line Tools.
private typealias LibraryState<Value> = SwiftUI.State<Value>

private enum LibraryStyle {
    static let accent = Color(red: 0.40, green: 0.88, blue: 0.74)
    static let background = Color(red: 0.075, green: 0.088, blue: 0.102)
    static let sidebar = Color(red: 0.055, green: 0.065, blue: 0.077)
    static let panel = Color.white.opacity(0.035)
}

struct PublisherView: View {
    @ObservedObject var model: PublisherAppModel
    @LibraryState private var dropTargeted = false
    var body: some View {
        HStack(spacing: 0) {
            sidebar.frame(width: 218)
            Divider().opacity(0.5)
            VStack(alignment: .leading, spacing: 0) {
                header.padding(.horizontal, 30).padding(.top, 28).padding(.bottom, 22)
                library.padding(.horizontal, 30)
                footer.padding(.horizontal, 30).padding(.vertical, 16)
            }
            .background(LibraryStyle.background)
        }
        .background(LibraryStyle.background)
        .preferredColorScheme(.dark)
        .tint(LibraryStyle.accent)
        .overlay {
            if dropTargeted {
                RoundedRectangle(cornerRadius: 14).fill(LibraryStyle.accent.opacity(0.12))
                    .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(LibraryStyle.accent, lineWidth: 2))
                    .padding(8).allowsHitTesting(false)
            }
        }
        .onDrop(of: [.fileURL], isTargeted: $dropTargeted) { providers in
            guard !model.libraryInteractionDisabled else { return false }
            Task { @MainActor in
                var urls: [URL] = []
                for provider in providers {
                    if let url = await droppedURL(provider) { urls.append(url) }
                }
                model.addFiles(urls)
            }
            return !providers.isEmpty
        }
        .sheet(isPresented: $model.showUploads) { UploadQueueView(model: model) }
        .onChange(of: model.searchText) { _, _ in model.trimSelection() }
        .onChange(of: model.kindFilter) { _, _ in model.trimSelection() }

    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 11) {
                Image(systemName: "arrow.up.arrow.down.square.fill")
                    .font(.system(size: 29, weight: .light)).foregroundStyle(LibraryStyle.accent)
                VStack(alignment: .leading, spacing: 2) {
                    Text("MCC").font(.system(size: 20, weight: .bold, design: .rounded))
                    Text("FORGE PUBLISHER").font(.system(size: 9, weight: .semibold)).tracking(1.4).foregroundStyle(.secondary)
                }
            }.padding(.horizontal, 21).padding(.top, 29).padding(.bottom, 37)
            Text("LIBRARY").font(.system(size: 10, weight: .semibold)).tracking(1.8).foregroundStyle(.secondary)
                .padding(.horizontal, 23).padding(.bottom, 11)
            HStack(spacing: 11) {
                Image(systemName: "person.2.fill").frame(width: 18)
                Text("Shared Files").font(.system(size: 13, weight: .semibold))
                Spacer(minLength: 0)
                if model.fileShareHasLoaded {
                    Text("\(model.fileShareItems.count)").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }
            }
            .foregroundStyle(LibraryStyle.accent)
            .padding(.horizontal, 13).padding(.vertical, 11)
            .background(LibraryStyle.accent.opacity(0.09), in: RoundedRectangle(cornerRadius: 8))
            .padding(.horizontal, 10).padding(.bottom, 4)
            Spacer()
            Button { model.showUploads = true } label: {
                HStack(spacing: 10) {
                    Image(systemName: "tray.and.arrow.up")
                    Text("Upload Queue")
                    Spacer()
                    if !model.uploadQueue.isEmpty {
                        Text("\(model.uploadQueue.count)").font(.caption.monospacedDigit())
                    }
                }.font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
                    .padding(13).background(LibraryStyle.panel, in: RoundedRectangle(cornerRadius: 8))
            }.buttonStyle(.plain).padding(.horizontal, 13).padding(.bottom, 20)
            Divider().opacity(0.4)
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 9) {
                    Image(systemName: "person.crop.circle.fill").font(.title2).foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(model.account?.gamertag ?? "Your Xbox account").font(.system(size: 12, weight: .semibold)).lineLimit(1)
                        HStack(spacing: 5) {
                            Circle().fill(model.account == nil ? Color.secondary : LibraryStyle.accent).frame(width: 5, height: 5)
                            Text(model.isPreview ? "Preview · sample files" : model.account == nil ? "Not connected" : "Connected to MCC")
                                .font(.system(size: 10)).foregroundStyle(.secondary)
                        }
                    }
                }
                if model.account == nil || model.fileShareNeedsSignIn {
                    Button(model.fileShareNeedsSignIn ? "Sign in again" : "Sign in with Microsoft") { Task { await model.signIn() } }
                        .buttonStyle(.borderedProminent).controlSize(.small).frame(maxWidth: .infinity)
                        .disabled(model.operationInProgress)
                } else {
                    Button("Sign out") { Task { await model.signOut() } }
                        .buttonStyle(.plain).font(.caption).foregroundStyle(.secondary).disabled(model.operationInProgress)
                }
            }.padding(20)
        }.background(LibraryStyle.sidebar)
    }

    private var header: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 7) {
                Text("YOUR MCC LIBRARY").font(.system(size: 10, weight: .semibold)).tracking(2).foregroundStyle(LibraryStyle.accent.opacity(0.8))
                Text("Shared Files").font(.system(size: 30, weight: .semibold))
                Text("Maps and gametypes on your MCC File Share.")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
            }
            Spacer()
            Button { model.chooseFiles() } label: { Label("Upload Files", systemImage: "plus") }
                .buttonStyle(.borderedProminent).controlSize(.large)
                .disabled(model.libraryInteractionDisabled)
        }
    }

    private var library: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass").font(.system(size: 13)).foregroundStyle(.secondary)
                    TextField("Search names, descriptions, games…", text: $model.searchText).textFieldStyle(.plain).font(.system(size: 12))
                    if !model.searchText.isEmpty {
                        Button { model.searchText = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }.buttonStyle(.plain)
                    }
                }.padding(10).background(LibraryStyle.panel, in: RoundedRectangle(cornerRadius: 8))
                Picker("File type", selection: $model.kindFilter) {
                    ForEach(LibraryKindFilter.allCases) { Text($0.rawValue).tag($0) }
                }.pickerStyle(.segmented).frame(width: 244).labelsHidden()
                Button { Task { await model.refreshFileShare() } } label: { Image(systemName: "arrow.clockwise").frame(width: 22, height: 22) }
                    .help("Refresh Shared Files").disabled(model.operationInProgress || model.account == nil)
            }
            if let warning = model.fileShareWarning { LibraryNotice(text: warning, warning: true) }
            if let warning = model.sharedUploadJournalMessage { LibraryNotice(text: warning, warning: true) }
            if let warning = model.fileShareDeletionJournalMessage { LibraryNotice(text: warning, warning: true) }
            if let deletion = model.fileShareDeletionMessage { LibraryNotice(text: deletion, warning: model.fileShareDeletionHasWarning) }
            HStack(spacing: 11) {
                Text(model.selectedFileShareItems.isEmpty ? "\(model.filteredFileShareItems.count) file\(model.filteredFileShareItems.count == 1 ? "" : "s")" : "\(model.selectedFileShareItems.count) selected")
                    .font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
                if !model.filteredFileShareItems.isEmpty {
                    Button(model.fileShareSelection.isEmpty ? "Select all" : "Clear selection") {
                        if model.fileShareSelection.isEmpty { model.selectAllVisible() } else { model.fileShareSelection = [] }
                    }.buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(LibraryStyle.accent).disabled(model.libraryInteractionDisabled)
                }
                Spacer()
                if let item = model.selectedFileShareItem {
                    Menu {
                        Text(item.title)
                        if !item.description.isEmpty { Text(item.description) }
                        Text("Item ID: \(item.id)")
                        if let uploadID = item.protocolFileName { Text("Upload ID: \(uploadID)") }
                        if let modified = item.modifiedAt { Text("Modified \(modified.formatted(date: .abbreviated, time: .shortened))") }
                    } label: { Image(systemName: "info.circle") }.menuStyle(.borderlessButton).fixedSize().help("File details")
                }
                Button { Task { await model.downloadSelectedFileShareItem() } } label: { Label("Download", systemImage: "arrow.down.to.line") }
                    .disabled(model.operationInProgress || model.selectedFileShareItems.isEmpty)
                Button(role: .destructive) { Task { await model.deleteSelectedFileShareItem() } } label: { Image(systemName: "trash") }
                    .help("Delete selected files from Shared Files")
                    .disabled(!model.canDeleteSelection)
            }.controlSize(.small)
            if model.account == nil {
                empty(title: "Your files start here", symbol: "person.crop.circle", text: "Sign in with Microsoft to browse your MCC maps and gametypes.")
            } else if model.fileShareLoading && model.fileShareItems.isEmpty {
                empty(title: "Loading your library", symbol: "arrow.triangle.2.circlepath", text: "Connecting to Shared Files…")
            } else if model.filteredFileShareItems.isEmpty {
                empty(title: model.fileShareError ? "Library unavailable" : model.fileShareItems.isEmpty ? "No files yet" : "No matching files", symbol: model.fileShareError ? "wifi.exclamationmark" : "tray", text: model.fileShareError ? "Refresh to try connecting again." : model.fileShareItems.isEmpty ? "Upload a Reach map or gametype to get started." : "Try a different search or file type.")
            } else {
                VStack(spacing: 0) {
                    HStack {
                        Text("NAME").frame(maxWidth: .infinity, alignment: .leading)
                        Text("GAME").frame(width: 130, alignment: .leading)
                        Text("TYPE").frame(width: 76, alignment: .leading)
                        Text("SIZE").frame(width: 62, alignment: .trailing)
                    }.font(.system(size: 9, weight: .semibold)).tracking(1.2).foregroundStyle(.tertiary)
                        .padding(.horizontal, 14).padding(.vertical, 10)
                    Divider().opacity(0.35)
                    List(selection: $model.fileShareSelection) {
                        ForEach(model.filteredFileShareItems) { item in FileLibraryRow(item: item).tag(item.id) }
                    }
                    .listStyle(.inset).scrollContentBackground(.hidden)
                    .accessibilityLabel("Shared Files, maps and gametypes; select multiple files with Command or Shift")
                    .disabled(model.libraryInteractionDisabled)
                }
                .background(LibraryStyle.panel, in: RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.white.opacity(0.04)))
            }
            if !model.transferResults.isEmpty { TransferResultsView(results: model.transferResults) }
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var footer: some View {
        VStack(spacing: 12) {
            if let title = model.batchTitle {
                HStack(spacing: 12) {
                    ProgressView(value: model.batchFraction).frame(width: 100)
                    Text("\(title) · \(model.batchCompleted) of \(model.batchTotal)").font(.caption)
                    Spacer()
                    Button(model.cancellationRequested ? "Stopping after current file…" : "Cancel remaining") { model.cancelBatch() }
                        .controlSize(.small).disabled(model.cancellationRequested)
                }
            }
            HStack(spacing: 9) {
                if model.fileShareLoading { ProgressView().controlSize(.mini) }
                else { Image(systemName: model.fileShareError ? "exclamationmark.circle" : "circle.fill").font(.system(size: model.fileShareError ? 11 : 5)).foregroundStyle(model.fileShareError ? Color.orange : LibraryStyle.accent.opacity(0.6)) }
                Text(model.account == nil ? model.message : model.fileShareMessage)
                    .font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(2).textSelection(.enabled)
                Spacer(minLength: 8)
                if model.fileShareSavedURL != nil {
                    Button("Reveal in Finder") { model.revealDownloadedFile() }.buttonStyle(.plain).font(.system(size: 10)).foregroundStyle(LibraryStyle.accent)
                }
            }
        }
    }
    private func empty(title: String, symbol: String, text: String) -> some View {
        ContentUnavailableView(title, systemImage: symbol, description: Text(text)).frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    private func droppedURL(_ provider: NSItemProvider) async -> URL? {
        await withCheckedContinuation { continuation in
            provider.loadItem(forTypeIdentifier: "public.file-url", options: nil) { item, _ in
                if let data = item as? Data { continuation.resume(returning: URL(dataRepresentation: data, relativeTo: nil)) }
                else { continuation.resume(returning: item as? URL) }
            }
        }
    }
}

private struct FileLibraryRow: View {
    let item: FileShareItem
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: item.kind == .map ? "map" : "gamecontroller")
                .font(.system(size: 17, weight: .light)).foregroundStyle(item.kind == .map ? LibraryStyle.accent : Color(red: 0.65, green: 0.70, blue: 0.97))
                .frame(width: 35, height: 35).background(Color.white.opacity(0.035), in: RoundedRectangle(cornerRadius: 8))
            VStack(alignment: .leading, spacing: 5) {
                Text(item.title).font(.system(size: 13, weight: .medium)).lineLimit(1)
                Text(item.description.isEmpty ? (item.baseMap ?? "MCC \(item.kind.label.lowercased())") : item.description)
                    .font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
            }.frame(maxWidth: .infinity, alignment: .leading)
            Text(item.game?.replacingOccurrences(of: "Halo: ", with: "Halo ") ?? "MCC").font(.system(size: 11)).foregroundStyle(.secondary).frame(width: 130, alignment: .leading)
            Text(item.kind.label).font(.system(size: 10)).foregroundStyle(.secondary).frame(width: 76, alignment: .leading)
            Text(item.fileSize.map { ByteCountFormatter.string(fromByteCount: Int64($0), countStyle: .file) } ?? "—")
                .font(.system(size: 10).monospacedDigit()).foregroundStyle(.secondary).frame(width: 62, alignment: .trailing)
        }.padding(.vertical, 9).help(item.title)
    }
}

private struct LibraryNotice: View {
    let text: String
    let warning: Bool
    var body: some View {
        DisclosureGroup {
            Text(text).font(.caption).foregroundStyle(.secondary).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding(.top, 4)
        } label: {
            Label(warning ? "Some files need attention" : "Library updated", systemImage: warning ? "exclamationmark.circle" : "checkmark.circle")
                .font(.system(size: 11)).foregroundStyle(warning ? Color.orange : LibraryStyle.accent)
        }.padding(10).background((warning ? Color.orange : LibraryStyle.accent).opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
    }
}

private struct TransferResultsView: View {
    let results: [LibraryTransferResult]
    var body: some View {
        DisclosureGroup("Last operation · \(results.filter { $0.state == .succeeded }.count) complete, \(results.filter { $0.state.isWarning }.count) need attention") {
            ScrollView {
                VStack(alignment: .leading, spacing: 9) {
                    ForEach(results) { result in
                        HStack(alignment: .top, spacing: 9) {
                            Image(systemName: result.state.symbol).foregroundStyle(result.state.isWarning ? Color.orange : LibraryStyle.accent)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(result.title).font(.caption.weight(.medium))
                                Text(result.detail).font(.caption2).foregroundStyle(.secondary).textSelection(.enabled)
                            }
                            Spacer()
                        }
                    }
                }.padding(.top, 8)
            }.frame(maxHeight: 130)
        }.font(.system(size: 11)).foregroundStyle(.secondary).padding(12).background(LibraryStyle.panel, in: RoundedRectangle(cornerRadius: 8))
    }
}

private struct UploadQueueView: View {
    @ObservedObject var model: PublisherAppModel
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Upload to Shared Files").font(.title2.weight(.semibold))
                    Text("Halo: Reach · maps (.mvar) and gametypes (.bin)").font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                Button { model.showUploads = false } label: { Image(systemName: "xmark").padding(4) }.buttonStyle(.plain).help("Close upload queue")
            }
            if model.uploadQueue.isEmpty {
                ContentUnavailableView("Add your next creation", systemImage: "tray.and.arrow.up", description: Text("Choose multiple files or drag maps and gametypes into the app."))
                    .frame(maxWidth: .infinity, minHeight: 240)
            } else {
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(model.uploadQueue) { entry in
                            HStack(alignment: .center, spacing: 12) {
                                if entry.state == .working { ProgressView().controlSize(.small).frame(width: 22) }
                                else { Image(systemName: entry.state.symbol).foregroundStyle(entry.state.isWarning ? Color.orange : LibraryStyle.accent).frame(width: 22) }
                                VStack(alignment: .leading, spacing: 5) {
                                    Text(entry.title).font(.system(size: 13, weight: .medium))
                                    Text(entry.sourceURL.lastPathComponent).font(.system(size: 10)).foregroundStyle(.tertiary)
                                    Text(entry.detail).font(.system(size: 11)).foregroundStyle(entry.state.isWarning ? Color.orange : .secondary).textSelection(.enabled)
                                }.frame(maxWidth: .infinity, alignment: .leading)
                                if let variant = entry.variant { Text(variant.kind.label).font(.caption).foregroundStyle(.secondary) }
                                if model.canReviewUpload(entry) {
                                    Button("Review…") { model.reviewPendingUpload(entry.id) }.controlSize(.small).disabled(model.libraryInteractionDisabled)
                                }
                                Button { model.removeUpload(entry.id) } label: { Image(systemName: "xmark.circle").foregroundStyle(.secondary) }
                                    .buttonStyle(.plain).disabled(model.libraryInteractionDisabled).help("Remove from queue")
                            }.padding(13)
                            Divider().opacity(0.3)
                        }
                    }
                }.frame(minHeight: 220, maxHeight: 380).background(LibraryStyle.panel, in: RoundedRectangle(cornerRadius: 10))
            }
            if let title = model.batchTitle {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("\(title) · \(model.batchCompleted) of \(model.batchTotal)").font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Button(model.cancellationRequested ? "Stopping…" : "Cancel remaining") { model.cancelBatch() }.controlSize(.small).disabled(model.cancellationRequested)
                    }
                    ProgressView(value: model.batchFraction)
                }
            } else if model.account == nil {
                Text("Sign in with Microsoft from the library to upload your files.").font(.caption).foregroundStyle(.secondary)
            } else if !model.historyAvailable || !model.sharedUploadJournalAvailable {
                Text("Shared uploads are paused because upload or recovery records could not be saved safely.").font(.caption).foregroundStyle(.orange)
            }
            HStack {
                Button("Add Files…") { model.chooseFiles() }.disabled(model.libraryInteractionDisabled)
                if model.failedUploadCount > 0 {
                    Button("Retry failed") { model.retryFailedUploads() }.disabled(model.libraryInteractionDisabled)
                }
                if !model.uploadQueue.isEmpty { Button("Clear finished") { model.clearFinishedUploads() }.buttonStyle(.plain).font(.caption).foregroundStyle(.secondary).disabled(model.libraryInteractionDisabled) }
                Spacer()
                Button("Upload \(model.readyUploadCount) File\(model.readyUploadCount == 1 ? "" : "s")") { Task { await model.publish() } }
                    .buttonStyle(.borderedProminent).controlSize(.large).disabled(!model.canUpload)
            }
        }.padding(26).frame(width: 680).background(LibraryStyle.background).preferredColorScheme(.dark).tint(LibraryStyle.accent)
    }
}
