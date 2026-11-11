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
                // `--exercise-capture` (demo only) runs a digitize capture, stops it after a
                // second, then runs a short one to completion: a check of both ways a run ends.
                if arguments.contains("--exercise-capture"), let controller = model.controller {
                    await controller.startLog(AcquisitionPlan(pacing: .fastest, stop: .samples(10_000)), name: "Stopped early", purpose: .digitize)
                    try? await Task.sleep(for: .seconds(1))
                    controller.stopLog()
                    while controller.isLogging { try? await Task.sleep(for: .milliseconds(50)) }
                    await controller.startLog(AcquisitionPlan(pacing: .fastest, stop: .samples(300)), name: "Ran to the end", purpose: .digitize)
                }
            } else if let flag = arguments.firstIndex(of: "--connect"), flag + 1 < arguments.count {
                await model.connect(to: .host(arguments[flag + 1]))
            }
            // `--exercise-log` / `--exercise-digitize` start one run with the meter's current
            // settings, for screenshots and checks where nothing can press Start.
            if let controller = model.controller {
                if arguments.contains("--exercise-log") {
                    await controller.startLog(
                        AcquisitionPlan(pacing: .interval(0.1), stop: .duration(30)), name: "Slow sine, 30 s")
                } else if arguments.contains("--exercise-digitize") {
                    await controller.startLog(
                        AcquisitionPlan(pacing: .interval(0.001), stop: .samples(500), trigger: .level(0.5, rising: true), pretriggerSamples: 100),
                        name: "10 Hz sine, level trigger", purpose: .digitize)
                }
            }
        }
    }
}
