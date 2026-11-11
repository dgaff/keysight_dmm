import DMMKit
import SwiftUI

/// Shows the connection screen or the main window, depending on whether a meter is connected.
struct RootView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Group {
            if let controller = model.controller {
                MainView(controller: controller)
            } else {
                ConnectionView()
            }
        }
        .frame(minWidth: 900, minHeight: 600)
        .task {
            // `--demo` connects to the simulator at launch, for testing.
            // `--connect <address>` connects to that meter at launch.
            let arguments = CommandLine.arguments
            guard model.controller == nil else { return }
            if arguments.contains("--demo") {
                await model.connect(to: .simulator)
            } else if let flag = arguments.firstIndex(of: "--connect"), flag + 1 < arguments.count {
                await model.connect(to: .host(arguments[flag + 1]))
            }
        }
    }
}
