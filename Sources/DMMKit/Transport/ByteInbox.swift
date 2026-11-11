import Foundation

/// Thread-safe receive buffer shared between a transport's receive loop (producer) and
/// the single `SCPISession` that owns the transport (consumer).
///
/// Waiting is done with a continuation plus a dispatch timer rather than task-group
/// racing, because a pending `NWConnection.receive` cannot be cancelled and would
/// otherwise keep a timed-out query from returning.
public final class ByteInbox: @unchecked Sendable {
    private enum Wake { case ready, timedOut, failed(SCPIError) }

    private let lock = NSLock()
    private var buffer = Data()
    /// How far `buffer` has already been searched for a newline, so long ASCII
    /// responses arriving in many chunks are not rescanned from the start each time.
    private var scanned = 0
    private var failure: SCPIError?
    private var waiter: CheckedContinuation<Wake, Never>?
    private var waiterID: UInt64 = 0

    public init() {}

    // MARK: Producer side

    public func append(_ data: Data) {
        lock.lock()
        buffer.append(data)
        let w = waiter
        waiter = nil
        lock.unlock()
        w?.resume(returning: .ready)
    }

    /// Marks the stream as dead. Bytes already buffered can still be consumed.
    public func fail(_ error: SCPIError) {
        lock.lock()
        if failure == nil { failure = error }
        let w = waiter
        waiter = nil
        lock.unlock()
        w?.resume(returning: .ready)
    }

    // MARK: Consumer side

    /// Drops everything buffered. Used to resynchronise after a timed-out query.
    public func discardAll() {
        lock.lock()
        buffer.removeAll(keepingCapacity: false)
        scanned = 0
        lock.unlock()
    }

    /// Returns the next newline-terminated line, without the terminator (LF or CRLF).
    public func line(timeout: Duration) async throws(SCPIError) -> Data {
        try await next(timeout: timeout) { buffer, scanned in
            guard let nl = buffer[scanned...].firstIndex(of: 0x0A) else {
                scanned = buffer.count
                return nil
            }
            var line = Data(buffer[..<nl])
            if line.last == 0x0D { line.removeLast() }
            buffer.removeSubrange(0...nl)
            scanned = 0
            return line
        }
    }

    /// Returns exactly `count` bytes.
    public func bytes(_ count: Int, timeout: Duration) async throws(SCPIError) -> Data {
        if count == 0 { return Data() }
        return try await next(timeout: timeout) { buffer, scanned in
            guard buffer.count >= count else { return nil }
            let out = Data(buffer[..<count])
            buffer.removeSubrange(0..<count)
            scanned = 0
            return out
        }
    }

    private func next(
        timeout: Duration,
        _ extract: (inout Data, inout Int) -> Data?
    ) async throws(SCPIError) -> Data {
        let deadline = ContinuousClock.now + timeout
        while true {
            var result: Data?
            let wake: Wake = await withCheckedContinuation { continuation in
                lock.lock()
                if let value = extract(&buffer, &scanned) {
                    result = value
                    lock.unlock()
                    continuation.resume(returning: .ready)
                    return
                }
                if let failure {
                    lock.unlock()
                    continuation.resume(returning: .failed(failure))
                    return
                }
                let remaining = deadline - ContinuousClock.now
                if remaining <= .zero {
                    lock.unlock()
                    continuation.resume(returning: .timedOut)
                    return
                }
                waiterID &+= 1
                let id = waiterID
                waiter = continuation
                lock.unlock()
                DispatchQueue.global().asyncAfter(deadline: .now() + remaining.timeInterval) { [self] in
                    lock.lock()
                    guard waiterID == id, let w = waiter else { lock.unlock(); return }
                    waiter = nil
                    lock.unlock()
                    w.resume(returning: .timedOut)
                }
            }
            if let result { return result }
            switch wake {
            case .ready: continue
            case .timedOut: throw .timeout(command: "")
            case .failed(let error): throw error
            }
        }
    }
}

extension Duration {
    /// Seconds as a `Double`.
    public var timeInterval: TimeInterval {
        let c = components
        return TimeInterval(c.seconds) + TimeInterval(c.attoseconds) * 1e-18
    }
}
