import Foundation
import Testing
@testable import DMMKit

@Suite struct AcquisitionTests {
    /// Runs a plan against the simulator and returns what the stream produced.
    private func run(
        _ plan: AcquisitionPlan, on sim: SimulatedMeter = SimulatedMeter(), cancelAfter: Duration? = nil
    ) async throws -> (info: AcquisitionInfo?, readings: [Reading], end: AcquisitionEnd?, total: Int, sim: SimulatedMeter) {
        let meter = try await Multimeter.connect(transport: sim)
        let acquisition = meter.acquire(plan)
        let task = Task {
            var info: AcquisitionInfo?
            var readings: [Reading] = []
            var end: AcquisitionEnd?
            var total = 0
            for try await event in acquisition.events {
                switch event {
                case .started(let i): info = i
                case .readings(let batch): readings += batch
                case .finished(let e, let t): end = e; total = t
                }
            }
            return (info, readings, end, total)
        }
        if let cancelAfter {
            try await Task.sleep(for: cancelAfter)
            acquisition.stop()
        }
        let result = try await task.value
        return (result.0, result.1, result.2, result.3, sim)
    }

    @Test func fixedCountCompletesAndRestoresSettings() async throws {
        let result = try await run(AcquisitionPlan(pacing: .interval(0.002), stop: .samples(250)))
        #expect(result.end == .completed)
        #expect(result.total == 250)
        #expect(result.readings.count == 250)
        #expect(result.readings.allSatisfy { $0.isValid && abs($0.value - 1.2345678) < 0.001 })
        #expect(result.info?.interval == 0.002)
        #expect(result.info?.expectedCount == 250)
        #expect(result.info?.autorangeOn == true)

        // The meter is left as it was found.
        let meter = try await Multimeter.connect(transport: result.sim)
        #expect(try await meter.session.query("SAMP:SOUR?") == "IMM")
        #expect(SCPIValue.parseInt(try await meter.session.query("SAMP:COUN?")) == 1)
        #expect(try await meter.session.query("FORM:DATA?") == "ASC,9")
        #expect(try await meter.session.drainErrors().isEmpty)
        #expect(try await meter.read().isValid)
    }

    @Test func durationSetsCountFromInterval() async throws {
        let result = try await run(AcquisitionPlan(pacing: .interval(0.01), stop: .duration(0.5)))
        #expect(result.info?.expectedCount == 51)
        #expect(result.total == 51)
        #expect(result.end == .completed)
    }

    @Test func fastestUsesTheMetersMinimumInterval() async throws {
        let result = try await run(AcquisitionPlan(pacing: .fastest, stop: .samples(20)))
        #expect(result.info?.interval == 0.001)
        #expect(result.info?.minimumInterval == 0.001)
        #expect(result.total == 20)
    }

    @Test func manualRunStopsOnCancelAndKeepsWhatWasTaken() async throws {
        let result = try await run(AcquisitionPlan(pacing: .interval(0.005), stop: .manual), cancelAfter: .milliseconds(700))
        #expect(result.end == .stopped)
        #expect(result.info?.expectedCount == nil)
        #expect(result.total == result.readings.count)
        #expect(result.total > 20)
        #expect(result.sim.received.contains("ABOR"))
    }

    @Test func tooShortAnIntervalIsRejectedWithTheLimit() async throws {
        let sim = SimulatedMeter()
        await #expect(throws: AcquisitionError.intervalTooShort(requested: 0.0001, minimum: 0.001)) {
            _ = try await run(AcquisitionPlan(pacing: .interval(0.0001), stop: .samples(5)), on: sim)
        }
        // Settings are restored even when setup fails part-way.
        let meter = try await Multimeter.connect(transport: sim)
        #expect(try await meter.session.query("SAMP:SOUR?") == "IMM")
    }
}
