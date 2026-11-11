import DMMKit
import SwiftUI

struct SidebarView: View {
    let controller: MeterController
    @Binding var selection: SidebarSection?

    var body: some View {
        List(selection: $selection) {
            Section {
                ForEach(SidebarSection.work) { section in
                    Label(section.title, systemImage: section.symbol).tag(section)
                }
            }
            Section("Instrument") {
                Label(SidebarSection.meter.title, systemImage: SidebarSection.meter.symbol)
                    .tag(SidebarSection.meter)
                Label(SidebarSection.console.title, systemImage: SidebarSection.console.symbol)
                    .tag(SidebarSection.console)
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            MeterInfoFooter(controller: controller)
        }
        .navigationSplitViewColumnWidth(min: 190, ideal: 210, max: 260)
    }
}

/// Which meter this is, where it is, and whether the link is up.
struct MeterInfoFooter: View {
    let controller: MeterController

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Divider().padding(.bottom, 6)
            HStack(spacing: 6) {
                Text("Keysight \(controller.identity.model)").font(.headline)
                if controller.isSimulated {
                    Text("Demo")
                        .font(.caption2.weight(.semibold))
                        .padding(.horizontal, 6).padding(.vertical, 1)
                        .background(.tint.opacity(0.15), in: Capsule())
                        .foregroundStyle(.tint)
                }
            }
            // `--redact` hides the serial number and address, for screenshots meant to be shared.
            if CommandLine.arguments.contains("--redact") {
                Text("Serial MY00000000")
                Text("192.168.1.100:5025")
            } else {
                Text("Serial \(controller.identity.serialNumber)")
                Text(controller.endpointDescription).lineLimit(1).truncationMode(.middle)
            }
            HStack(spacing: 5) {
                Circle().fill(statusColor).frame(width: 7, height: 7)
                Text(statusText)
            }
            .padding(.top, 2)
        }
        .font(.callout)
        .foregroundStyle(.secondary)
        .textSelection(.enabled)
        .padding(.horizontal, 14)
        .padding(.bottom, 12)
    }

    private var statusText: String {
        switch controller.link {
        case .connected: "Connected"
        case .lost: "Connection lost"
        case .closed: "Closed"
        }
    }

    private var statusColor: Color {
        switch controller.link {
        case .connected: .green
        case .lost: .red
        case .closed: .gray
        }
    }
}
