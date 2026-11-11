import AppKit
import SwiftUI

@main
struct KeysightDMMApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var model = AppModel()

    var body: some Scene {
        Window("Keysight DMM", id: "main") {
            RootView()
                .environment(model)
                .preferredColorScheme(.light)  // PRD: light design
                .onAppear {
                    delegate.model = model
                    model.startBrowsing()
                }
        }
        .defaultSize(width: 1180, height: 760)
        .commands {
            CommandGroup(replacing: .newItem) {}
            AppCommands(model: model)
        }
    }
}

/// Makes quitting orderly: the meter is handed back to local control and the socket is
/// closed before the process exits, whichever way the app is asked to quit.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    var model: AppModel?
    private var signalSources: [any DispatchSourceSignal] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        // When run unbundled (swift run) the process is not a regular app by default.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
        // kill / Ctrl-C take the same orderly path as Quit.
        for number in [SIGTERM, SIGINT] {
            signal(number, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: number, queue: .main)
            source.setEventHandler { NSApp.terminate(nil) }
            source.resume()
            signalSources.append(source)
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let model, model.controller != nil else { return .terminateNow }
        Task {
            await model.disconnect()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}
