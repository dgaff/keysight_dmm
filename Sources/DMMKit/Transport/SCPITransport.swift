import Foundation
import Network

/// A byte pipe to an instrument. Received bytes are delivered into `inbox`.
public protocol SCPITransport: Sendable {
    var inbox: ByteInbox { get }
    /// Human-readable description of the far end, for status display.
    var endpointDescription: String { get }
    func connect(timeout: Duration) async throws(SCPIError)
    func send(_ data: Data) async throws(SCPIError)
    /// Closes the connection. Safe to call more than once.
    func close() async
}

/// Raw SCPI socket (Keysight instruments listen on TCP 5025).
public final class TCPTransport: SCPITransport, @unchecked Sendable {
    public static let scpiRawPort: UInt16 = 5025

    public let inbox = ByteInbox()
    public let endpointDescription: String

    private let connection: NWConnection
    private let queue = DispatchQueue(label: "DMMKit.TCPTransport")
    private let lock = NSLock()
    private var connectContinuation: CheckedContinuation<SCPIError?, Never>?
    private var lastWaitingReason: String?
    private var closed = false

    /// Connects to a resolved Bonjour service or any other `NWEndpoint`.
    public init(endpoint: NWEndpoint) {
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        tcp.enableKeepalive = true
        tcp.keepaliveIdle = 10
        tcp.keepaliveInterval = 5
        tcp.keepaliveCount = 3
        let parameters = NWParameters(tls: nil, tcp: tcp)
        connection = NWConnection(to: endpoint, using: parameters)
        endpointDescription = "\(endpoint)"
    }

    public convenience init(host: String, port: UInt16 = TCPTransport.scpiRawPort) {
        self.init(endpoint: .hostPort(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: port)!))
    }

    public func connect(timeout: Duration) async throws(SCPIError) {
        let failure: SCPIError? = await withCheckedContinuation { continuation in
            lock.lock()
            connectContinuation = continuation
            lock.unlock()
            connection.stateUpdateHandler = { [weak self] state in self?.handle(state) }
            connection.start(queue: queue)
            queue.asyncAfter(deadline: .now() + timeout.timeInterval) { [weak self] in
                guard let self else { return }
                let reason = self.lastWaitingReason.map { " (\($0))" } ?? ""
                self.finishConnect(.connectionFailed("timed out after \(Int(timeout.timeInterval)) s\(reason)"))
            }
        }
        if let failure {
            connection.cancel()
            throw failure
        }
        receiveLoop()
    }

    private func handle(_ state: NWConnection.State) {
        switch state {
        case .ready:
            finishConnect(nil)
        case .waiting(let error):
            // Keep waiting until the connect timeout: the path may come up. Remember why.
            lastWaitingReason = error.localizedDescription
        case .failed(let error):
            finishConnect(.connectionFailed(error.localizedDescription))
            inbox.fail(.connectionLost(error.localizedDescription))
        case .cancelled:
            finishConnect(.connectionFailed("cancelled"))
            inbox.fail(.notConnected)
        default:
            break
        }
    }

    private func finishConnect(_ failure: SCPIError?) {
        lock.lock()
        let c = connectContinuation
        connectContinuation = nil
        lock.unlock()
        c?.resume(returning: failure)
    }

    private func receiveLoop() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 16) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data, !data.isEmpty { self.inbox.append(data) }
            if let error {
                self.inbox.fail(.connectionLost(error.localizedDescription))
            } else if isComplete {
                self.inbox.fail(.connectionLost("closed by the instrument"))
            } else {
                self.receiveLoop()
            }
        }
    }

    public func send(_ data: Data) async throws(SCPIError) {
        let failure: SCPIError? = await withCheckedContinuation { continuation in
            connection.send(content: data, completion: .contentProcessed { error in
                continuation.resume(returning: error.map { .connectionLost($0.localizedDescription) })
            })
        }
        if let failure { throw failure }
    }

    public func close() async {
        let alreadyClosed = lock.withLock {
            let was = closed
            closed = true
            return was
        }
        guard !alreadyClosed else { return }
        // Send FIN and give the instrument a moment to see an orderly close, then tear down.
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let once = OnceFlag()
            connection.send(content: nil, contentContext: .finalMessage, isComplete: true,
                            completion: .contentProcessed { _ in
                if once.set() { continuation.resume() }
            })
            queue.asyncAfter(deadline: .now() + 0.5) {
                if once.set() { continuation.resume() }
            }
        }
        connection.cancel()
    }
}

/// Returns `true` exactly once.
final class OnceFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    func set() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if done { return false }
        done = true
        return true
    }
}
