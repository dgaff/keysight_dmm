import DMMKit
import Foundation
import Observation

/// App-wide state: instrument discovery and the current connection.
@MainActor
@Observable
final class AppModel {
    enum Target: Equatable {
        case discovered(DiscoveredInstrument)
        case host(String)
        case simulator
    }

    private(set) var instruments: [DiscoveredInstrument] = []
    /// Set when Bonjour browsing cannot run (no local-network permission, firewall…).
    private(set) var discoveryProblem: String?
    private(set) var isConnecting = false
    /// Why the last connection attempt failed.
    private(set) var connectionError: String?
    private(set) var controller: MeterController?

    /// Last manually entered address, remembered between launches.
    var manualHost: String = UserDefaults.standard.string(forKey: "manualHost") ?? "" {
        didSet { UserDefaults.standard.set(manualHost, forKey: "manualHost") }
    }

    @ObservationIgnored private var browseTask: Task<Void, Never>?

    func startBrowsing() {
        guard browseTask == nil else { return }
        browseTask = Task { [weak self] in
            let browser = InstrumentBrowser()
            for await event in browser.events() {
                guard let self else { break }
                switch event {
                case .instruments(let found):
                    self.instruments = found
                    self.discoveryProblem = nil
                case .unavailable(let why):
                    self.discoveryProblem = why
                }
            }
        }
    }

    func stopBrowsing() {
        browseTask?.cancel()
        browseTask = nil
    }

    func connect(to target: Target) async {
        guard !isConnecting else { return }
        isConnecting = true
        connectionError = nil
        defer { isConnecting = false }
        await disconnect()

        let transport: any SCPITransport
        switch target {
        case .discovered(let instrument): transport = TCPTransport(endpoint: instrument.endpoint)
        case .host(let host): transport = TCPTransport(host: host.trimmingCharacters(in: .whitespaces))
        case .simulator: transport = SimulatedMeter()
        }
        do {
            let connected = try await MeterController.connect(transport: transport, isSimulated: target == .simulator)
            guard connected.model != nil else {
                await connected.shutdown()
                connectionError = "\(connected.identity.manufacturer) \(connected.identity.model) is not a Truevolt multimeter (34460A, 34461A, 34465A or 34470A)."
                return
            }
            controller = connected
            connected.startLive()
        } catch {
            connectionError = error.localizedDescription
        }
    }

    /// Orderly disconnect; safe to call when not connected.
    func disconnect() async {
        guard let current = controller else { return }
        controller = nil
        await current.shutdown()
    }
}
