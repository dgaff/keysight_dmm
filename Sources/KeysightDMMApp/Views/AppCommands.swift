import SwiftUI

struct AppCommands: Commands {
    let model: AppModel
    @AppStorage("showInspector") private var showInspector = true

    var body: some Commands {
        CommandMenu("Meter") {
            if let controller = model.controller {
                Button(controller.isLive ? "Stop" : "Run") {
                    Task { if controller.isLive { await controller.stopLive() } else { controller.startLive() } }
                }
                .keyboardShortcut("r", modifiers: .command)
                Button("Clear") { controller.clearHistory() }
                    .keyboardShortcut("k", modifiers: .command)
                Button("Refresh from Meter") { Task { await controller.adoptCurrentState() } }
                Divider()
            } else {
                Button("Run") {}.keyboardShortcut("r", modifiers: .command).disabled(true)
                Button("Clear") {}.keyboardShortcut("k", modifiers: .command).disabled(true)
                Button("Refresh from Meter") {}.disabled(true)
                Divider()
            }
            Button("Disconnect") { Task { await model.disconnect() } }
                .keyboardShortcut("d", modifiers: [.command, .shift])
                .disabled(model.controller == nil)
        }
        CommandGroup(after: .toolbar) {
            Button(showInspector ? "Hide Settings" : "Show Settings") { showInspector.toggle() }
                .keyboardShortcut("i", modifiers: [.command, .option])
        }
    }
}
