import DMMKit
import SwiftUI

/// Shown while no meter is connected: discovered instruments, a manual address and the demo meter.
struct ConnectionView: View {
    @Environment(AppModel.self) private var model
    @State private var selection: DiscoveredInstrument.ID?

    private var selectedInstrument: DiscoveredInstrument? {
        model.instruments.first { $0.id == selection && $0.isSupportedMultimeter }
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 4) {
                Image(systemName: "gauge.with.dots.needle.33percent")
                    .font(.system(size: 36, weight: .light))
                    .foregroundStyle(.tint)
                Text("Connect to a multimeter")
                    .font(.title2.weight(.semibold))
                Text("Choose an instrument found on your network, enter its address, or try the demo meter.")
                    .foregroundStyle(.secondary)
            }
            .multilineTextAlignment(.center)
            .padding(.top, 36)
            .padding(.bottom, 20)

            VStack(spacing: 18) {
                instrumentList
                    .frame(minHeight: 170, maxHeight: 280)
                connectBar
                feedback
                Divider()
                manualAddress
            }
            .frame(maxWidth: 560)
            .padding(.horizontal, 24)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.background)
        .disabled(model.isConnecting)
    }

    // MARK: Instrument list

    @ViewBuilder
    private var instrumentList: some View {
        if model.instruments.isEmpty {
            VStack(spacing: 10) {
                if model.discoveryProblem == nil {
                    ProgressView().controlSize(.small)
                    Text("Looking for instruments…").foregroundStyle(.secondary)
                    Text("Instruments that advertise themselves on the network appear here.")
                        .font(.callout).foregroundStyle(.tertiary)
                } else {
                    Image(systemName: "network.slash").font(.title).foregroundStyle(.secondary)
                    Text("No instruments found").foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            List(model.instruments, selection: $selection) { instrument in
                InstrumentRow(instrument: instrument)
                    .tag(instrument.id)
                    .selectionDisabled(!instrument.isSupportedMultimeter)
                    .contentShape(Rectangle())
                    .onTapGesture(count: 2) {
                        if instrument.isSupportedMultimeter {
                            Task { await model.connect(to: .discovered(instrument)) }
                        }
                    }
            }
            .listStyle(.inset(alternatesRowBackgrounds: false))
            .scrollContentBackground(.hidden)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.separator))
        }
    }

    private var connectBar: some View {
        HStack {
            Button("Demo meter") { Task { await model.connect(to: .simulator) } }
                .help("Connect to a simulated 34470A. Nothing on the network is touched.")
            Spacer()
            if model.isConnecting {
                ProgressView().controlSize(.small)
                Text("Connecting…").foregroundStyle(.secondary)
            }
            Button("Connect") {
                if let instrument = selectedInstrument {
                    Task { await model.connect(to: .discovered(instrument)) }
                }
            }
            .keyboardShortcut(.defaultAction)
            .disabled(selectedInstrument == nil)
        }
    }

    // MARK: Feedback

    @ViewBuilder
    private var feedback: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let problem = model.discoveryProblem {
                Label {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Discovery is not working: \(problem)")
                        Text("Local network access may need to be allowed for this app in System Settings › Privacy & Security › Local Network. You can still connect by address.")
                            .foregroundStyle(.secondary)
                    }
                } icon: {
                    Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange)
                }
            }
            if let error = model.connectionError {
                Label {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(error).foregroundStyle(.red)
                        Text("If the address is right, a firewall on this Mac (Little Snitch, for example) may be blocking the app from reaching the meter on TCP port 5025.")
                            .foregroundStyle(.secondary)
                    }
                } icon: {
                    Image(systemName: "xmark.octagon").foregroundStyle(.red)
                }
            }
        }
        .font(.callout)
        .frame(maxWidth: .infinity, alignment: .leading)
        .textSelection(.enabled)
    }

    private var manualAddress: some View {
        @Bindable var model = model
        return VStack(alignment: .leading, spacing: 6) {
            Text("Connect by address").font(.headline)
            HStack {
                TextField("IP address or host name", text: $model.manualHost)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(connectManual)
                Button("Connect", action: connectManual)
                    .disabled(model.manualHost.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            Text("For example 192.168.1.109. The meter listens on TCP port 5025.")
                .font(.callout).foregroundStyle(.secondary)
        }
        .padding(.bottom, 24)
    }

    private func connectManual() {
        guard !model.manualHost.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        Task { await model.connect(to: .host(model.manualHost)) }
    }
}

private struct InstrumentRow: View {
    let instrument: DiscoveredInstrument

    var body: some View {
        let supported = instrument.isSupportedMultimeter
        HStack(spacing: 12) {
            Image(systemName: supported ? "gauge.with.dots.needle.50percent" : "bolt.horizontal")
                .font(.title3)
                .frame(width: 28)
                .foregroundStyle(supported ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.body.weight(.medium))
                Text(detail).font(.callout).foregroundStyle(.secondary)
            }
            Spacer()
            if !supported {
                Text("Not a multimeter").font(.callout).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
        .opacity(supported ? 1 : 0.5)
    }

    private var title: String {
        [instrument.manufacturer, instrument.model].compactMap { $0 }.joined(separator: " ").nonEmpty ?? instrument.name
    }

    private var detail: String {
        var parts: [String] = []
        if let serial = instrument.serialNumber { parts.append("Serial \(serial)") }
        if let firmware = instrument.firmware { parts.append("Firmware \(firmware)") }
        return parts.isEmpty ? instrument.name : parts.joined(separator: "  ·  ")
    }
}

private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}
