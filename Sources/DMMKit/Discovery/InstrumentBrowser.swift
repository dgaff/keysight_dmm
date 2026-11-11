import Foundation
import Network

/// An instrument advertising a raw SCPI socket over Bonjour (LXI mDNS).
public struct DiscoveredInstrument: Sendable, Identifiable, Hashable {
    /// Bonjour service name, e.g. "Keysight 34470A Digital Multimeter - MY64017466".
    public let name: String
    public let manufacturer: String?
    public let model: String?
    public let serialNumber: String?
    public let firmware: String?
    /// Service endpoint; hand it straight to `TCPTransport(endpoint:)`, which resolves it.
    public let endpoint: NWEndpoint

    public var id: String { name }

    public var truevoltModel: TruevoltModel? { model.flatMap(TruevoltModel.init(rawValue:)) }
    /// True for the multimeters this app can drive.
    public var isSupportedMultimeter: Bool { truevoltModel != nil }
}

/// Browses the local network for `_scpi-raw._tcp` services.
///
/// Keysight LXI instruments publish TXT keys `Manufacturer`, `Model`, `SerialNumber`
/// and `FirmwareVersion`, so the list can be labelled without connecting to anything.
public final class InstrumentBrowser: @unchecked Sendable {
    public static let serviceType = "_scpi-raw._tcp"

    public enum Event: Sendable {
        case instruments([DiscoveredInstrument])
        /// Browsing is blocked or failed (no local-network permission, firewall, …).
        case unavailable(String)
    }

    private let browser: NWBrowser
    private let queue = DispatchQueue(label: "DMMKit.InstrumentBrowser")

    public init() {
        let parameters = NWParameters()
        parameters.includePeerToPeer = false
        browser = NWBrowser(for: .bonjourWithTXTRecord(type: Self.serviceType, domain: nil), using: parameters)
    }

    /// Starts browsing. The stream yields the complete, sorted list each time it changes
    /// and ends when the consumer stops iterating or `stop()` is called.
    public func events() -> AsyncStream<Event> {
        AsyncStream { continuation in
            browser.stateUpdateHandler = { state in
                switch state {
                case .failed(let error), .waiting(let error):
                    continuation.yield(.unavailable(error.localizedDescription))
                case .cancelled:
                    continuation.finish()
                default:
                    break
                }
            }
            browser.browseResultsChangedHandler = { results, _ in
                continuation.yield(.instruments(Self.instruments(from: results)))
            }
            continuation.onTermination = { [browser] _ in browser.cancel() }
            browser.start(queue: queue)
        }
    }

    public func stop() { browser.cancel() }

    static func instruments(from results: Set<NWBrowser.Result>) -> [DiscoveredInstrument] {
        var byName: [String: DiscoveredInstrument] = [:]
        for result in results {
            guard case .service(let name, _, _, _) = result.endpoint else { continue }
            var txt: [String: String] = [:]
            if case .bonjour(let record) = result.metadata { txt = record.dictionary }
            // The same service shows up once per interface; keep one entry per name.
            byName[name] = DiscoveredInstrument(
                name: name,
                manufacturer: txt["Manufacturer"],
                model: txt["Model"],
                serialNumber: txt["SerialNumber"],
                firmware: txt["FirmwareVersion"],
                endpoint: result.endpoint
            )
        }
        return byName.values.sorted {
            // Supported multimeters first, then alphabetical.
            ($0.isSupportedMultimeter ? 0 : 1, $0.name) < ($1.isSupportedMultimeter ? 0 : 1, $1.name)
        }
    }
}
