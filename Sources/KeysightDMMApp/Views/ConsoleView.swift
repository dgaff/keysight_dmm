import DMMKit
import SwiftUI
import AppKit

/// Read-only log of everything sent to and received from the meter.
struct ConsoleView: View {
    let controller: MeterController
    @State private var paused = false

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(Array(controller.traffic.enumerated()), id: \.offset) { index, event in
                            row(event).id(index)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .onChange(of: controller.traffic.count) { _, count in
                    if !paused, count > 0 { proxy.scrollTo(count - 1, anchor: .bottom) }
                }
                .overlay {
                    if controller.traffic.isEmpty {
                        Text("Nothing has been sent yet.").foregroundStyle(.secondary)
                    }
                }
            }
            Divider()
            HStack {
                Toggle("Pause scrolling", isOn: $paused)
                Spacer()
                Text("\(controller.traffic.count) lines").foregroundStyle(.secondary)
                Button("Copy all", action: copyAll)
                    .disabled(controller.traffic.isEmpty)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
        }
        .background(.background)
    }

    private func row(_ event: SCPITrafficEvent) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(Self.time(event.date)).foregroundStyle(.tertiary)
            Text(Self.marker(event.direction)).foregroundStyle(color(event.direction)).frame(width: 14)
            Text(event.text)
                .italic(event.direction == .note)
                .foregroundStyle(color(event.direction))
                .textSelection(.enabled)
        }
        .font(.system(size: 12, design: .monospaced))
    }

    private func color(_ direction: SCPITrafficEvent.Direction) -> Color {
        switch direction {
        case .sent: .accentColor
        case .received: .primary
        case .note: .secondary
        }
    }

    private static func marker(_ direction: SCPITrafficEvent.Direction) -> String {
        switch direction {
        case .sent: "→"
        case .received: "←"
        case .note: "·"
        }
    }

    /// HH:MM:SS.mmm, built by hand so it never depends on the locale.
    private static func time(_ date: Date) -> String {
        let c = Calendar.current.dateComponents([.hour, .minute, .second, .nanosecond], from: date)
        func two(_ n: Int) -> String { n < 10 ? "0\(n)" : "\(n)" }
        let ms = (c.nanosecond ?? 0) / 1_000_000
        let msText = ms < 10 ? "00\(ms)" : (ms < 100 ? "0\(ms)" : "\(ms)")
        return "\(two(c.hour ?? 0)):\(two(c.minute ?? 0)):\(two(c.second ?? 0)).\(msText)"
    }

    private func copyAll() {
        let text = controller.traffic.map { "\(Self.time($0.date)) \(Self.marker($0.direction)) \($0.text)" }
            .joined(separator: "\n")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}
