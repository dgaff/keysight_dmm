import DMMKit
import SwiftUI

/// The window shown while a meter is connected.
struct MainView: View {
    let controller: MeterController
    @Environment(AppModel.self) private var model
    @AppStorage("showInspector") private var showInspector = true
    @State private var section: SidebarSection? = SidebarSection.launchSelection ?? .measure
    @State private var logSetup = LogSetup()
    @State private var captures = CaptureStore()
    @State private var selectedRecording: Recording.ID?
    @State private var showErrors = false

    var body: some View {
        NavigationSplitView {
            SidebarView(controller: controller, selection: $section)
        } detail: {
            VStack(spacing: 0) {
                StatusBanners(controller: controller)
                page
            }
            .navigationTitle(section?.title ?? "Measure")
            .navigationSubtitle(controller.isSimulated ? "Demo meter" : "Keysight \(controller.identity.model)")
        }
        .toolbar { toolbarContent }
    }

    @ViewBuilder
    private var page: some View {
        switch section ?? .measure {
        case .measure: MeasureView(controller: controller)
        case .dataLog:
            DataLogView(controller: controller, setup: logSetup) { id in
                selectedRecording = id
                section = .recordings
            }
        case .recordings: RecordingsView(controller: controller, selection: $selectedRecording)
        case .files: FilesView(controller: controller)
        case .screenCapture: ScreenCaptureView(controller: controller, store: captures)
        case .console: ConsoleView(controller: controller)
        case let other: PlaceholderPage(section: other)
        }
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            Button {
                Task {
                    if controller.isLive { await controller.stopLive() } else { controller.startLive() }
                }
            } label: {
                Label(controller.isLive ? "Stop" : "Run", systemImage: controller.isLive ? "stop.fill" : "play.fill")
            }
            .help(controller.isLive ? "Stop live readings (⌘R)" : "Start live readings (⌘R)")
            .disabled(controller.link != .connected || controller.isLogging)

            Button { controller.clearHistory() } label: {
                Label("Clear", systemImage: "trash")
            }
            .help("Clear readings, statistics and the chart (⌘K)")

            Button { Task { await controller.adoptCurrentState() } } label: {
                Label("Refresh from meter", systemImage: "arrow.clockwise")
            }
            .help("Read the function and settings from the meter again, for example after using its front panel")
            .disabled(controller.link != .connected || controller.isApplying)
        }

        ToolbarItemGroup(placement: .primaryAction) {
            Button { showErrors.toggle() } label: {
                Label(
                    controller.errors.isEmpty ? "Errors" : "\(controller.errors.count) errors",
                    systemImage: controller.errors.isEmpty ? "checkmark.circle" : "exclamationmark.triangle.fill"
                )
            }
            .help(controller.errors.isEmpty ? "No errors" : "Show errors from the meter")
            .disabled(controller.errors.isEmpty)
            .popover(isPresented: $showErrors, arrowEdge: .bottom) {
                ErrorsPopover(controller: controller)
            }

            if section == .measure || section == nil {
                Button { showInspector.toggle() } label: {
                    Label("Settings", systemImage: "sidebar.trailing")
                }
                .help("Show or hide the settings panel")
            }

            Button { Task { await model.disconnect() } } label: {
                Label("Disconnect", systemImage: "eject")
            }
            .help("Disconnect and return the meter to front-panel control")
        }
    }
}

private struct ErrorsPopover: View {
    let controller: MeterController

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Errors").font(.headline)
                Spacer()
                Button("Clear") { controller.clearErrors() }
            }
            if controller.errors.isEmpty {
                Text("No errors.").foregroundStyle(.secondary)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(controller.errors.reversed()) { error in
                            VStack(alignment: .leading, spacing: 1) {
                                Text(error.date, format: .dateTime.hour().minute().second())
                                    .font(.caption).foregroundStyle(.secondary)
                                Text(error.text).textSelection(.enabled)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 260)
            }
        }
        .padding(14)
        .frame(width: 360)
    }
}
