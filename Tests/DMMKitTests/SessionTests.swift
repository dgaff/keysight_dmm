import Foundation
import Testing
@testable import DMMKit

/// Transport whose responses are scripted per command, for exact wire-level tests.
final class ScriptedTransport: SCPITransport, @unchecked Sendable {
    let inbox = ByteInbox()
    let endpointDescription = "scripted"
    private let lock = NSLock()
    private var script: [String: [Data]] = [:]
    private(set) var sent: [String] = []

    func on(_ command: String, reply: Data) { lock.withLock { script[command, default: []].append(reply) } }
    func on(_ command: String, reply: String) { on(command, reply: Data(reply.utf8)) }

    func connect(timeout: Duration) async throws(SCPIError) {}
    func close() async { inbox.fail(.notConnected) }
    func send(_ data: Data) async throws(SCPIError) {
        let command = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .newlines)
        let reply: Data? = lock.withLock {
            sent.append(command)
            guard var queue = script[command], !queue.isEmpty else { return nil }
            let next = queue.removeFirst()
            script[command] = queue
            return next
        }
        if let reply {
            // Deliver in two pieces to exercise reassembly.
            let split = reply.count / 2
            inbox.append(reply.prefix(split))
            inbox.append(reply.suffix(from: reply.startIndex + split))
        }
    }
}

@Suite struct SessionTests {
    @Test func queryAndCRLFTrimming() async throws {
        let transport = ScriptedTransport()
        transport.on("*IDN?", reply: "Keysight Technologies,34470A,X,1\r\n")
        let session = SCPISession(transport: transport)
        #expect(try await session.query("*IDN?") == "Keysight Technologies,34470A,X,1")
    }

    @Test func definiteLengthBlockWithEmbeddedNewlines() async throws {
        let transport = ScriptedTransport()
        let payload = Data([0x0A, 0x00, 0x23, 0x0A, 0xFF, 0x0D, 0x0A, 0x31])
        transport.on("HCOP:SDUM:DATA?", reply: Data("#18".utf8) + payload + Data("\n".utf8))
        transport.on("*OPC?", reply: "1\n")
        let session = SCPISession(transport: transport)
        #expect(try await session.queryBlock("HCOP:SDUM:DATA?") == payload)
        // The stream must still be aligned afterwards.
        #expect(try await session.query("*OPC?") == "1")
    }

    @Test func asciiReadingBlock() async throws {
        let transport = ScriptedTransport()
        transport.on("R? 3", reply: "#247-4.98748741E-01,-4.35163427E-01,-7.41859188E-01\n")
        let session = SCPISession(transport: transport)
        let block = try await session.queryBlock("R? 3")
        #expect(SCPIValue.parseDoubleList(String(decoding: block, as: UTF8.self)) == [-0.498748741, -0.435163427, -0.741859188])
    }

    @Test func nonBlockResponseIsReportedNotHung() async throws {
        let transport = ScriptedTransport()
        transport.on("R?", reply: "oops\n")
        let session = SCPISession(transport: transport)
        await #expect(throws: SCPIError.malformedResponse(command: "R?", response: "oops")) {
            try await session.queryBlock("R?")
        }
    }

    @Test func setSurfacesInstrumentErrors() async throws {
        let transport = ScriptedTransport()
        transport.on("SYST:ERR?", reply: "-222,\"Data out of range\"\n")
        transport.on("SYST:ERR?", reply: "+0,\"No error\"\n")
        let session = SCPISession(transport: transport)
        let expected = SCPIError.instrument([InstrumentError(code: -222, message: "Data out of range")], command: "VOLT:RANG 5000")
        await #expect(throws: expected) { try await session.set("VOLT:RANG 5000") }
    }

    @Test func timeoutThenResync() async throws {
        let transport = ScriptedTransport()
        let session = SCPISession(transport: transport)
        await session.setDefaultTimeout(.milliseconds(80))
        await #expect(throws: SCPIError.timeout(command: "READ?")) { try await session.query("READ?") }
        // A late answer to the timed-out query must not be taken as the next response.
        transport.inbox.append(Data("+1.0E+00\n".utf8))
        transport.on("*OPC?", reply: "1\n")
        #expect(try await session.query("*OPC?") == "1")
    }

    @Test func concurrentCallersDoNotInterleave() async throws {
        let meter = SimulatedMeter()
        try await meter.connect(timeout: .seconds(1))
        let session = SCPISession(transport: meter)
        try await withThrowingTaskGroup(of: Void.self) { group in
            for i in 0..<50 {
                group.addTask {
                    if i.isMultiple(of: 2) {
                        let idn = try await session.query("*IDN?")
                        #expect(idn == SimulatedMeter.idn)
                    } else {
                        let opc = try await session.query("*OPC?")
                        #expect(opc == "1")
                    }
                }
            }
            try await group.waitForAll()
        }
    }

    @Test func connectionLossFailsPendingQuery() async throws {
        let transport = ScriptedTransport()
        let session = SCPISession(transport: transport)
        Task {
            try? await Task.sleep(for: .milliseconds(50))
            transport.inbox.fail(.connectionLost("cable pulled"))
        }
        await #expect(throws: SCPIError.connectionLost("cable pulled")) { try await session.query("READ?") }
    }
}

@Suite struct MultimeterTests {
    @Test func connectReadAndDisconnectAgainstSimulator() async throws {
        let sim = SimulatedMeter()
        let meter = try await Multimeter.connect(transport: sim)
        #expect(meter.identity.truevoltModel == .m34470A)
        #expect(meter.errorsAtConnect.isEmpty)
        #expect(try await meter.function() == .dcVoltage)

        try await meter.setFunction(.resistance4W)
        #expect(try await meter.function() == .resistance4W)
        let reading = try await meter.read()
        #expect(reading.isValid)
        #expect(abs(reading.value - 9998.71) < 1)

        await meter.disconnect()
        #expect(sim.received.last == "SYST:LOC")
        await #expect(throws: SCPIError.self) { try await meter.read() }
    }

    @Test func staleErrorsAreCollectedAtConnect() async throws {
        let sim = SimulatedMeter()
        sim.injectError(-113, "Undefined header")
        let meter = try await Multimeter.connect(transport: sim)
        #expect(meter.errorsAtConnect == [InstrumentError(code: -113, message: "Undefined header")])
    }
}
