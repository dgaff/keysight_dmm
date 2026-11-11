import DMMKit
import SwiftUI
import UniformTypeIdentifiers

/// Browser for the meter's internal storage and the USB stick in its front-panel port.
struct FilesView: View {
    enum Volume: String, CaseIterable, Identifiable {
        case internalStorage = "Internal", usb = "USB drive"
        var id: String { rawValue }
        var root: String { self == .internalStorage ? Multimeter.internalRoot : Multimeter.usbRoot }
    }

    private enum Load {
        case loading
        case loaded(MeterFolderListing)
        case failed
    }

    let controller: MeterController
    @State private var volume = Volume.internalStorage
    @State private var folder = Multimeter.internalRoot
    @State private var load = Load.loading
    @State private var reloadCount = 0
    @State private var selection: MeterFile.ID?
    @State private var message: String?
    @State private var messageIsError = false
    @State private var pendingDelete: MeterFile?
    @State private var pendingLoad: MeterFile?
    @State private var working = false

    private struct LoadKey: Hashable {
        var folder: String
        var reload: Int
    }

    private var listing: MeterFolderListing? {
        if case .loaded(let listing) = load { return listing }
        return nil
    }

    private var selectedFile: MeterFile? {
        listing?.files.first { $0.id == selection }
    }

    /// The folder one level up; nil at the top.
    static func parent(of folder: String) -> String? {
        if folder.hasSuffix("\\") { return nil }
        guard let slash = folder.lastIndex(of: "\\") else { return nil }
        let head = String(folder[..<slash])
        return head.hasSuffix(":") ? head + "\\" : head
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            controls
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            footer
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 18)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(.background)
        .task(id: LoadKey(folder: folder, reload: reloadCount)) { await reload() }
        .confirmationDialog(
            "Delete this file from the meter?",
            isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                if let file = pendingDelete { Task { await delete(file) } }
                pendingDelete = nil
            }
            Button("Cancel", role: .cancel) { pendingDelete = nil }
        } message: {
            Text("“\(pendingDelete?.name ?? "")” will be erased from the meter. This cannot be undone.")
        }
        .confirmationDialog(
            "Load this state?",
            isPresented: Binding(get: { pendingLoad != nil }, set: { if !$0 { pendingLoad = nil } }),
            titleVisibility: .visible
        ) {
            Button("Load", role: .destructive) {
                if let file = pendingLoad { Task { await loadState(file) } }
                pendingLoad = nil
            }
            Button("Cancel", role: .cancel) { pendingLoad = nil }
        } message: {
            Text("This replaces the meter's current setup with “\(pendingLoad?.name ?? "")”.")
        }
    }

    // MARK: Pieces

    private var controls: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                Picker("Storage", selection: $volume) {
                    ForEach(Volume.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 220)
                .onChange(of: volume) { _, new in
                    selection = nil
                    message = nil
                    folder = new.root
                }
                Spacer()
                Button { reloadCount += 1 } label: { Label("Refresh", systemImage: "arrow.clockwise") }
                    .disabled(isLoading)
                Button { Task { await download() } } label: { Label("Download…", systemImage: "arrow.down.circle") }
                    .disabled(selectedFile == nil || selectedFile?.kind == .folder || working)
                Button { pendingLoad = selectedFile } label: { Label("Load state…", systemImage: "arrow.uturn.backward.circle") }
                    .disabled(selectedFile?.kind != .state || working)
                Button(role: .destructive) { pendingDelete = selectedFile } label: { Label("Delete…", systemImage: "trash") }
                    .disabled(selectedFile == nil || selectedFile?.kind == .folder || working)
            }
            HStack(spacing: 8) {
                Button { if let up = Self.parent(of: folder) { navigate(to: up) } } label: {
                    Label("Back", systemImage: "chevron.left")
                }
                .disabled(Self.parent(of: folder) == nil)
                Text(folder)
                    .font(.system(.callout, design: .monospaced))
                    .textSelection(.enabled)
                    .lineLimit(1)
                    .truncationMode(.head)
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 5))
            }
        }
    }

    private var isLoading: Bool {
        if case .loading = load { return true }
        return false
    }

    @ViewBuilder
    private var content: some View {
        switch load {
        case .loading:
            VStack(spacing: 8) {
                ProgressView()
                Text("Reading the folder…").foregroundStyle(.secondary)
            }
        case .failed:
            if volume == .usb, folder == Multimeter.usbRoot {
                ContentUnavailableView(
                    "No USB drive",
                    systemImage: "externaldrive",
                    description: Text("No USB drive in the meter's front-panel port. Insert one and choose Refresh."))
            } else {
                ContentUnavailableView {
                    Label("Could not read this folder", systemImage: "folder.badge.questionmark")
                } description: {
                    Text("The meter did not return a listing. The error list in the toolbar may say why.")
                } actions: {
                    Button("Try again") { reloadCount += 1 }
                }
            }
        case .loaded(let listing):
            if listing.files.isEmpty {
                ContentUnavailableView("This folder is empty", systemImage: "folder")
            } else {
                Table(listing.files, selection: $selection) {
                    TableColumn("Name") { file in
                        Label(file.name, systemImage: Self.symbol(for: file.kind))
                    }
                    .width(min: 160, ideal: 300)
                    TableColumn("Kind") { file in
                        Text(Self.kindText(file.kind)).foregroundStyle(.secondary)
                    }
                    .width(min: 120, ideal: 160)
                    TableColumn("Size") { file in
                        Text(file.kind == .folder ? "–" : ByteText.format(file.size))
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                    .width(min: 80, ideal: 100)
                }
                .contextMenu(forSelectionType: MeterFile.ID.self) { _ in
                } primaryAction: { ids in
                    if let id = ids.first, let file = listing.files.first(where: { $0.id == id }), file.kind == .folder {
                        navigate(to: file.path)
                    }
                }
            }
        }
    }

    private var footer: some View {
        HStack {
            if let message {
                Label(message, systemImage: messageIsError ? "xmark.octagon" : "checkmark.circle")
                    .foregroundStyle(messageIsError ? Color.red : Color.secondary)
                    .textSelection(.enabled)
            }
            Spacer()
            if let listing {
                Text("\(listing.files.count) items · \(ByteText.format(listing.bytesUsed)) used · \(ByteText.format(listing.bytesFree)) free")
                    .foregroundStyle(.secondary)
            }
        }
        .font(.callout)
        .frame(minHeight: 18)
    }

    // MARK: Behaviour

    private static func symbol(for kind: MeterFile.Kind) -> String {
        switch kind {
        case .folder: "folder"
        case .state: "gearshape"
        case .preferences: "slider.horizontal.3"
        case .data: "tablecells"
        case .other: "doc"
        }
    }

    private static func kindText(_ kind: MeterFile.Kind) -> String {
        switch kind {
        case .folder: "Folder"
        case .state: "Instrument state"
        case .preferences: "Preferences"
        case .data: "Readings (text)"
        case .other: "File"
        }
    }

    private func navigate(to path: String) {
        selection = nil
        message = nil
        folder = path
    }

    private func reload() async {
        load = .loading
        let wanted = folder
        let result = await controller.listFiles(in: wanted)
        if Task.isCancelled || wanted != folder { return }
        if let result { load = .loaded(result) } else { load = .failed }
    }

    private func download() async {
        guard let file = selectedFile, file.kind != .folder else { return }
        guard let url = FileSaving.chooseURL(suggestedName: file.name, type: Self.contentType(for: file)) else { return }
        working = true
        defer { working = false }
        message = "Downloading \(file.name)…"
        messageIsError = false
        guard let data = await controller.download(file) else {
            message = "Could not download \(file.name) from the meter."
            messageIsError = true
            return
        }
        if let problem = await FileSaving.write(data, to: url) {
            message = "Could not save the file: \(problem)"
            messageIsError = true
        } else {
            message = "Saved \(url.lastPathComponent) (\(ByteText.format(data.count)))."
        }
    }

    private func loadState(_ file: MeterFile) async {
        working = true
        defer { working = false }
        let ok = await controller.loadState(from: file)
        message = ok ? "Loaded \(file.name) into the meter." : "Could not load \(file.name)."
        messageIsError = !ok
    }

    private func delete(_ file: MeterFile) async {
        working = true
        defer { working = false }
        let ok = await controller.deleteFile(file)
        message = ok ? "Deleted \(file.name) from the meter." : "Could not delete \(file.name)."
        messageIsError = !ok
        selection = nil
        reloadCount += 1
    }

    private static func contentType(for file: MeterFile) -> UTType {
        UTType(filenameExtension: (file.name as NSString).pathExtension) ?? .data
    }
}
