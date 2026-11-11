import DMMKit
import SwiftUI

/// Notices shown above the page: a dropped connection, or a trigger setting that pauses live readings.
struct StatusBanners: View {
    let controller: MeterController
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 0) {
            if case .lost(let reason) = controller.link {
                banner(tint: .red, symbol: "wifi.exclamationmark") {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Connection to the meter was lost").font(.headline)
                        Text(reason).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Back to connection screen") { Task { await model.disconnect() } }
                }
            } else if !controller.canRunLive {
                banner(tint: .orange, symbol: "pause.circle") {
                    Text("The meter is waiting for an external or bus trigger (\(controller.triggerSource)), so live readings are paused. Set the trigger source to IMM to resume.")
                    Spacer()
                }
            }
        }
    }

    private func banner<Content: View>(tint: Color, symbol: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(spacing: 10) {
            Image(systemName: symbol).foregroundStyle(tint).font(.title3)
            content()
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
        .background(tint.opacity(0.10))
        .overlay(alignment: .bottom) { Divider() }
    }
}
