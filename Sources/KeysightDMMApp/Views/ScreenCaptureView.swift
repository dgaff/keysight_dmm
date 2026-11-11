import AppKit
import Observation
import SwiftUI
import UniformTypeIdentifiers

/// Screen captures taken this session, kept by the window so they survive page changes.
@MainActor
@Observable
final class CaptureStore {
    struct Capture: Identifiable {
        let id = UUID()
        let number: Int
        let date: Date
        let data: Data
        let image: NSImage
        /// A copy on disk, so the picture can be dragged out to Finder or other apps.
        let fileURL: URL?
        var name: String { "Meter screen \(number)" }
    }

    private(set) var captures: [Capture] = []
    var selectedID: Capture.ID?
    private(set) var isCapturing = false
    private(set) var problem: String?
    private var counter = 0

    var selected: Capture? { captures.first { $0.id == selectedID } ?? captures.last }

    func capture(from controller: MeterController) async {
        guard !isCapturing else { return }
        isCapturing = true
        defer { isCapturing = false }
        guard let data = await controller.captureScreen(), let image = NSImage(data: data) else {
            problem = "The meter did not return a picture of its screen."
            return
        }
        problem = nil
        counter += 1
        let number = counter
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("KeysightDMM captures", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("Meter screen \(number).png")
        let written = (try? data.write(to: url)) != nil
        let capture = Capture(number: number, date: Date(), data: data, image: image, fileURL: written ? url : nil)
        captures.append(capture)
        selectedID = capture.id
    }
}

/// Captures the meter's display and shows it enlarged.
struct ScreenCaptureView: View {
    let controller: MeterController
    let store: CaptureStore
    @State private var autoRefresh = false
    @State private var seconds = 5
    @State private var message: String?

    var body: some View {
        @Bindable var store = store
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 14) {
                Button {
                    Task { await store.capture(from: controller) }
                } label: {
                    Label("Capture", systemImage: "camera")
                }
                .buttonStyle(.borderedProminent)
                .disabled(store.isCapturing || controller.link != .connected)
                if store.isCapturing { ProgressView().controlSize(.small).frame(width: 16, height: 16) }

                Toggle("Refresh every", isOn: $autoRefresh)
                Stepper(value: $seconds, in: 2...600) {
                    Text("\(seconds) s").monospacedDigit()
                }
                .fixedSize()
                .disabled(!autoRefresh)

                Spacer()
                Button { copy() } label: { Label("Copy", systemImage: "doc.on.doc") }
                    .disabled(store.selected == nil)
                Button { Task { await save() } } label: { Label("Save…", systemImage: "square.and.arrow.down") }
                    .disabled(store.selected == nil)
            }
            if let problem = store.problem {
                Label(problem, systemImage: "exclamationmark.triangle").foregroundStyle(.red).font(.callout)
            } else if let message {
                Label(message, systemImage: "checkmark.circle").foregroundStyle(.secondary).font(.callout)
            }

            GeometryReader { geometry in
                if let capture = store.selected {
                    picture(capture, in: geometry.size)
                        .frame(width: geometry.size.width, height: geometry.size.height)
                } else {
                    ContentUnavailableView(
                        "No capture yet",
                        systemImage: "camera.viewfinder",
                        description: Text("Press Capture to take a picture of the meter's display."))
                        .frame(width: geometry.size.width, height: geometry.size.height)
                }
            }

            if store.captures.count > 1 { strip }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 18)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(.background)
        .task(id: autoRefresh ? seconds : 0) {
            // Opening the page for the first time takes a capture, so it is never empty.
            if store.captures.isEmpty { await store.capture(from: controller) }
            guard autoRefresh else { return }
            while !Task.isCancelled {
                await store.capture(from: controller)
                try? await Task.sleep(for: .seconds(seconds))
            }
        }
    }

    /// The capture at its original size. It does not grow with the window; if the window
    /// is too small for it, it is reduced smoothly.
    private func picture(_ capture: CaptureStore.Capture, in available: CGSize) -> some View {
        let pixels = Self.pixelSize(of: capture.image)
        // Shown at the meter's own size (480 × 289), never enlarged with the window; only
        // shrunk if the window is too small to fit it.
        let fit = min(available.width / pixels.width, available.height / pixels.height)
        let integral = fit >= 1
        let factor = min(fit, 1)
        return Image(nsImage: capture.image)
            .resizable()
            .interpolation(integral ? .none : .high)
            .frame(width: pixels.width * factor, height: pixels.height * factor)
            .overlay(Rectangle().stroke(Color.secondary.opacity(0.35), lineWidth: 1))
            .shadow(color: .black.opacity(0.12), radius: 6, y: 2)
            .onDrag {
                if let url = capture.fileURL, let provider = NSItemProvider(contentsOf: url) { return provider }
                return NSItemProvider(object: capture.image)
            }
            .help("Drag the picture into Finder or another app")
            .accessibilityLabel("Picture of the meter's display")
    }

    private static func pixelSize(of image: NSImage) -> CGSize {
        if let rep = image.representations.first, rep.pixelsWide > 0, rep.pixelsHigh > 0 {
            return CGSize(width: rep.pixelsWide, height: rep.pixelsHigh)
        }
        return CGSize(width: max(image.size.width, 1), height: max(image.size.height, 1))
    }

    private var strip: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 8) {
                ForEach(store.captures.reversed()) { capture in
                    Button { store.selectedID = capture.id } label: {
                        Image(nsImage: capture.image)
                            .resizable()
                            .interpolation(.high)
                            .frame(width: 96, height: 58)
                            .overlay(Rectangle().stroke(capture.id == store.selected?.id ? Color.accentColor : Color.secondary.opacity(0.3), lineWidth: capture.id == store.selected?.id ? 2 : 1))
                    }
                    .buttonStyle(.plain)
                    .help("\(capture.name), taken at \(capture.date.formatted(date: .omitted, time: .standard))")
                }
            }
            .padding(2)
        }
        .frame(height: 68)
    }

    private func copy() {
        guard let capture = store.selected else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects([capture.image])
        message = "Copied \(capture.name)."
    }

    private func save() async {
        guard let capture = store.selected,
              let url = FileSaving.chooseURL(suggestedName: "\(capture.name).png", type: .png) else { return }
        if let problem = await FileSaving.write(capture.data, to: url) {
            message = "Could not save the picture: \(problem)"
        } else {
            message = "Saved \(url.lastPathComponent)."
        }
    }
}
