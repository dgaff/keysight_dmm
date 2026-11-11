import DMMKit
import SwiftUI

/// Placeholder shell: shows the connection picker or a bare readout. The real views
/// replace this file's contents.
struct RootView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if let controller = model.controller {
            VStack(spacing: 12) {
                Text(controller.function.displayName).font(.headline)
                Text(controller.latest.map {
                    EngineeringNotation.string($0.reading, unit: controller.unit, significantDigits: 8)
                } ?? "—")
                    .font(.system(size: 64, weight: .medium, design: .monospaced))
                Button("Disconnect") { Task { await model.disconnect() } }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            VStack(spacing: 12) {
                ForEach(model.instruments) { instrument in
                    Button(instrument.name) { Task { await model.connect(to: .discovered(instrument)) } }
                        .disabled(!instrument.isSupportedMultimeter)
                }
                Button("Demo meter") { Task { await model.connect(to: .simulator) } }
                if let error = model.connectionError { Text(error).foregroundStyle(.red) }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

struct AppCommands: Commands {
    let model: AppModel

    var body: some Commands {
        CommandMenu("Meter") {
            Button("Disconnect") { Task { await model.disconnect() } }
                .keyboardShortcut("d", modifiers: [.command, .shift])
                .disabled(model.controller == nil)
        }
    }
}
