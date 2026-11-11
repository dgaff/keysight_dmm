import DMMKit
import SwiftUI

/// Function picker, readout, statistics and chart together, with the settings inspector alongside.
struct MeasureView: View {
    let controller: MeterController
    @AppStorage("showInspector") private var showInspector = true

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            if controller.isLogging { loggingNotice }
            HStack(alignment: .center, spacing: 16) {
                FunctionPicker(controller: controller)
                RecordButton(controller: controller)
            }
            ReadoutView(controller: controller)
            StatisticsStrip(controller: controller)
            MeasureChart(controller: controller)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 18)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(.background)
        .inspector(isPresented: $showInspector) {
            SettingsInspector(controller: controller)
                .inspectorColumnWidth(min: 250, ideal: 290, max: 360)
        }
    }

    private var loggingNotice: some View {
        Label("A data log is running; live readings are paused.", systemImage: "pause.circle")
            .font(.callout)
            .padding(.horizontal, 10).padding(.vertical, 5)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 6))
    }
}

/// Keeps the live readings as a recording until pressed again.
struct RecordButton: View {
    let controller: MeterController

    var body: some View {
        HStack(spacing: 10) {
            if let capture = controller.liveCapture {
                HStack(spacing: 6) {
                    Circle().fill(.red).frame(width: 8, height: 8)
                    Text("Recording · \(capture.count) readings").monospacedDigit()
                }
                .font(.callout)
                Button { controller.stopLiveCapture() } label: {
                    Label("Stop recording", systemImage: "stop.circle")
                }
            } else {
                Button { controller.startLiveCapture(name: controller.suggestedName("recording")) } label: {
                    Label("Record", systemImage: "record.circle")
                }
                .help("Keep the live readings as a recording, then export them from Recordings")
                .disabled(controller.link != .connected || controller.isLogging || !controller.canRunLive)
            }
        }
    }
}
