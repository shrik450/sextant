import Foundation
import Synchronization
import Testing
@testable import SextantCore

/// Analyses of real grammars that are stopped: cancelled, out of time, or capturing too much.
@Suite(.serialized) struct AnalysisBudgetTests {
    /// A Swift file just within the analysis limit, which takes a while to analyze.
    private static let large: [String] = {
        var lines: [String] = []
        var bytes = 0
        var i = 0
        while bytes < ContentLimits.analysisBytes - 200 {
            let line = "func f\(i)(x: Int) -> Int { let y = x * \(i); return y + \"s\(i)\".count }"
            bytes += line.utf8.count + 1
            lines.append(line)
            i += 1
        }
        return lines
    }()

    private var swift: SyntaxLanguage {
        get throws { try #require(SyntaxRuntime.shared?.language(forPath: "a.swift")) }
    }

    @Test func aCancelledAnalysisStopsAtOnce() async throws {
        let swift = try swift
        let lines = Self.large
        let clock = ContinuousClock()
        let whole = try clock.measure { _ = try swift.analysis(of: lines, definitions: true) }
        let task = Task.detached { () -> AnalysisStop? in
            do throws(AnalysisStop) {
                _ = try swift.analysis(of: lines, definitions: true)
                return nil
            } catch {
                return error
            }
        }
        try await Task.sleep(for: whole / 10)
        let cancelled = clock.now
        task.cancel()
        #expect(await task.value == .cancelled)
        let after = clock.now - cancelled
        #expect(after < whole / 4, "stopped \(after) after cancelling an analysis that takes \(whole)")
    }

    @Test func anAnalysisPastItsTimeIsGivenUp() throws {
        let swift = try swift
        #expect(throws: AnalysisStop.tooSlow) { try swift.analysis(of: Self.large, definitions: true, budget: AnalysisBudget(time: .milliseconds(5))) }
    }

    @Test func aQueryCapturingTooMuchIsGivenUp() throws {
        let swift = try swift
        let lines = Array(Self.large.prefix(200))
        #expect(throws: AnalysisStop.tooManyCaptures) { try swift.analysis(of: lines, definitions: false, budget: AnalysisBudget(captures: 100)) }
        #expect(throws: AnalysisStop.tooManyCaptures) {
            try swift.names(of: lines, tokens: try swift.analysis(of: lines, definitions: false).tokens, budget: AnalysisBudget(captures: 100))
        }
        #expect(try swift.analysis(of: lines, definitions: true).definitions?.count == 2 * lines.count)
    }

    @Test func aVersionWhoseCallersAllLeaveStopsBeingAnalyzed() async throws {
        let swift = try swift
        let analysis = ContentAnalysis(cache: nil, memory: MemoryCache(budget: 1 << 30))
        let lines = Self.large
        let callers = (0..<2).map { _ in
            Task { await analysis.analysis(of: lines, oid: "large", language: swift, definitions: true) }
        }
        try await Task.sleep(for: .milliseconds(50))
        #expect(AnalysisGate.shared.running == 1)
        callers[0].cancel()
        try await Task.sleep(for: .milliseconds(50))
        #expect(AnalysisGate.shared.running == 1, "one caller still waits for it")
        callers[1].cancel()
        #expect(await callers[0].value == nil)
        #expect(await callers[1].value == nil)
        let stopped = ContinuousClock.now
        while AnalysisGate.shared.running > 0, ContinuousClock.now - stopped < .seconds(5) { try await Task.sleep(for: .milliseconds(5)) }
        #expect(ContinuousClock.now - stopped < .milliseconds(500))
        let again = await analysis.analysis(of: lines, oid: "large", language: swift, definitions: true)
        #expect(again?.definitions?.count == 2 * lines.count)
    }
}

@Suite struct AnalysisGateTests {
    @Test func textsRunTogetherOnlyWithinTheBudget() async {
        let gate = AnalysisGate(budget: 10)
        let peak = Peak()
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<6 {
                group.addTask {
                    _ = await gate.run(bytes: 4) {
                        peak.state.withLock { $0.now += 4; $0.most = max($0.most, $0.now) }
                        try? await Task.sleep(for: .milliseconds(10))
                        peak.state.withLock { $0.now -= 4 }
                    }
                }
            }
        }
        #expect(peak.state.withLock { $0.most } == 8)
        #expect(await gate.run(bytes: 50) { 1 } == 1, "a text over the whole budget runs alone")
    }

    @Test func aWaiterCancelledLeavesAtOnce() async throws {
        let gate = AnalysisGate(budget: 10)
        let holder = Task { await gate.run(bytes: 10) { try? await Task.sleep(for: .seconds(2)) } }
        try await Task.sleep(for: .milliseconds(20))
        let waiter = Task { await gate.run(bytes: 5) { "ran" } }
        try await Task.sleep(for: .milliseconds(20))
        waiter.cancel()
        #expect(await waiter.value == nil)
        holder.cancel()
        _ = await holder.value
        #expect(gate.running == 0)
        #expect(await gate.run(bytes: 5) { "ran" } == "ran")
    }
}

/// How many bytes ran at once, and the most that did.
private final class Peak: Sendable {
    let state = Mutex((now: 0, most: 0))
}
