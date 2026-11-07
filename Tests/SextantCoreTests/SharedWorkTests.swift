import Foundation
import Synchronization
import Testing
@testable import SextantCore

/// Checks that shared work runs once for everyone waiting, and stops only once no one is.
@Suite struct SharedWorkTests {
    /// Work that counts its runs and whether it saw itself cancelled, and finishes when told.
    final class Probe: Sendable {
        let runs = Mutex(0)
        let cancelled = Mutex(0)
        let release = Mutex(false)

        func work(_ value: Int) async -> Int? {
            runs.withLock { $0 += 1 }
            while !release.withLock({ $0 }) {
                if Task.isCancelled {
                    cancelled.withLock { $0 += 1 }
                    return nil
                }
                try? await Task.sleep(for: .milliseconds(5))
            }
            return value
        }

        func waitForRuns(_ n: Int) async {
            while runs.withLock({ $0 }) < n { try? await Task.sleep(for: .milliseconds(2)) }
        }
    }

    @Test func everyoneWaitingSharesOneRun() async {
        let shared = SharedWork<Int>(), probe = Probe()
        let a = Task { await shared.value { await probe.work(1) } }
        await probe.waitForRuns(1)
        let b = Task { await shared.value { await probe.work(2) } }
        try? await Task.sleep(for: .milliseconds(20))
        probe.release.withLock { $0 = true }
        #expect(await a.value == 1)
        #expect(await b.value == 1)
        #expect(probe.runs.withLock { $0 } == 1)
    }

    @Test func aCancelledWaiterStopsWaitingWhileTheRunGoesOnForOthers() async {
        let shared = SharedWork<Int>(), probe = Probe()
        let a = Task { await shared.value { await probe.work(1) } }
        await probe.waitForRuns(1)
        let b = Task { await shared.value { await probe.work(2) } }
        try? await Task.sleep(for: .milliseconds(20))
        a.cancel()
        #expect(await a.value == nil)
        #expect(shared.isRunning)
        probe.release.withLock { $0 = true }
        #expect(await b.value == 1)
        #expect(probe.cancelled.withLock { $0 } == 0)
    }

    @Test func theRunStopsOnceNoOneWaits() async {
        let shared = SharedWork<Int>(), probe = Probe()
        let a = Task { await shared.value { await probe.work(1) } }
        let b = Task { await shared.value { await probe.work(2) } }
        await probe.waitForRuns(1)
        a.cancel()
        b.cancel()
        #expect(await a.value == nil)
        #expect(await b.value == nil)
        while probe.cancelled.withLock({ $0 }) == 0 { try? await Task.sleep(for: .milliseconds(2)) }
        #expect(!shared.isRunning)
        let c = Task { await shared.value { await probe.work(3) } }
        await probe.waitForRuns(2)
        probe.release.withLock { $0 = true }
        #expect(await c.value == 3)
    }

    @Test func aWaiterCancelledBeforeItAsksStartsNothing() async {
        let shared = SharedWork<Int>(), probe = Probe()
        let a = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return await shared.value { await probe.work(1) }
        }
        #expect(await a.value == nil)
        #expect(probe.runs.withLock { $0 } == 0)
        #expect(!shared.isRunning)
    }
}
