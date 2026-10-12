import Foundation
import Testing
@testable import NotesCore

struct MaintenanceCallsTests {
    private final class Spy: MaintenanceRunning, @unchecked Sendable {
        private let lock = NSLock()
        private var _modes: [MaintenanceMode] = []
        var modes: [MaintenanceMode] { lock.withLock { _modes } }

        func run(_ mode: MaintenanceMode) async -> MaintenanceReport {
            lock.withLock { _modes.append(mode) }
            return MaintenanceReport()
        }
    }

    @Test func launchRunsStartupMode() async {
        let spy = Spy()
        _ = await MaintenanceCalls(runner: spy).runAtLaunch()
        #expect(spy.modes.count == 1)
        guard case .startup = spy.modes[0] else {
            Issue.record("expected .startup, got \(spy.modes[0])")
            return
        }
    }

    @Test func periodicRunKeepsTheCurrentQuickAddSession() async {
        let spy = Spy()
        let session = UUID()
        _ = await MaintenanceCalls(runner: spy).runPeriodically(currentStagingSession: session)
        guard case .periodic(let keeping) = spy.modes[0] else {
            Issue.record("expected .periodic, got \(spy.modes[0])")
            return
        }
        #expect(keeping == [session])
    }

    @Test func periodicRunWithoutASessionKeepsNothing() async {
        let spy = Spy()
        _ = await MaintenanceCalls(runner: spy).runPeriodically(currentStagingSession: nil)
        guard case .periodic(let keeping) = spy.modes[0] else {
            Issue.record("expected .periodic, got \(spy.modes[0])")
            return
        }
        #expect(keeping.isEmpty)
    }
}
