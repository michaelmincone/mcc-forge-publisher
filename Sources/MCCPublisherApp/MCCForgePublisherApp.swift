import SwiftUI
import AppKit

@main
struct MCCForgePublisherApp: App {
    @StateObject private var model = PublisherAppModel()
    var body: some Scene {
        WindowGroup("MCC Forge Publisher") {
            PublisherView(model: model)
                .frame(minWidth: 660, minHeight: 620)
                .task { await model.restore() }
                .onOpenURL { model.select($0) }
        }
        .windowStyle(.titleBar)
        .defaultSize(width: 660, height: 720)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Choose Map…") { model.chooseMap() }.keyboardShortcut("o")
            }
            CommandGroup(after: .appInfo) {
                Button("Service Configuration…") { model.chooseConfiguration() }
            }
        }
    }
}

struct PublisherView: View {
    @ObservedObject var model: PublisherAppModel
    private let green = Color(red: 0.47, green: 0.86, blue: 0.62)
    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            HStack(alignment: .top, spacing: 16) {
                Image(systemName: "arrow.up.document.fill")
                    .font(.system(size: 34)).foregroundStyle(green)
                    .padding(14).background(green.opacity(0.09), in: RoundedRectangle(cornerRadius: 16))
                VStack(alignment: .leading, spacing: 6) {
                    Text("MCC Forge Publisher").font(.system(size: 28, weight: .semibold))
                    Text("Publish Halo: Reach maps to your File Share.").foregroundStyle(.secondary)
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
                        .buttonStyle(.borderedProminent).tint(green).disabled(model.busy)
                } else {
                    Button("Sign out") { Task { await model.signOut() } }.disabled(model.busy)
                }
            }.padding(18).background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 12))
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
                Button(model.map == nil ? "Choose Map…" : "Choose a Different Map…") { model.chooseMap() }.disabled(model.busy)
            }
            .frame(maxWidth: .infinity, minHeight: 220).padding(20)
            .background(green.opacity(0.035), in: RoundedRectangle(cornerRadius: 16))
            .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(green.opacity(0.28), style: StrokeStyle(lineWidth: 1, dash: model.map == nil ? [6] : [])))
            .onDrop(of: [.fileURL], isTargeted: nil) { providers in
                guard !model.busy, let p = providers.first else { return false }
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
                    Button("Check Download") { Task { await model.checkDownload() } }.disabled(model.busy || model.account == nil)
                }
                Text("The stored file check does not confirm Xbox compatibility. Check the download in MCC on Xbox.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            HStack {
                Text("Your map file stays unchanged.").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Upload to File Share") { Task { await model.publish() } }
                    .buttonStyle(.borderedProminent).tint(green).controlSize(.large)
                    .disabled(model.busy || model.map == nil || model.account == nil || model.receipt != nil || !model.historyAvailable)
            }
        }.padding(30).preferredColorScheme(.dark)
    }
}
