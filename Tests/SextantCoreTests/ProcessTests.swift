import Foundation
import Testing
@testable import SextantCore

/// Runs real gits through `Git.run`, and checks how a run ends when it's cancelled, prints too
/// much, or stops reading its input.
@Suite struct ProcessTests {
    /// Waits until a file holds a process ID, and returns it.
    func pid(in url: URL) async throws -> pid_t {
        for _ in 0..<500 {
            if let s = try? String(contentsOf: url, encoding: .utf8), let pid = pid_t(s.trimmingCharacters(in: .whitespacesAndNewlines)) { return pid }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw GitError(message: "no process ID in \(url.path)")
    }

    func isRunning(_ pid: pid_t) -> Bool { kill(pid, 0) == 0 }

    /// Whether a process is gone within a moment: one killed with its parent lingers until
    /// launchd reaps it.
    func isGone(_ pid: pid_t) async -> Bool {
        for _ in 0..<100 where isRunning(pid) { try? await Task.sleep(for: .milliseconds(5)) }
        return !isRunning(pid)
    }

    @Test func cancellingARunStopsGitAndWhatItStartedPromptly() async throws {
        let dir = try ScratchRepo("process-cancel")
        let shellPid = dir.root.appendingPathComponent("shell.pid"), sleepPid = dir.root.appendingPathComponent("sleep.pid")
        let alias = "alias.slow=!echo $$ > shell.pid; sleep 30 & echo $! > sleep.pid; wait"
        let run = Task { try await dir.repo.run(["-c", alias, "slow"], limit: Git.Limit.value) }
        let shell = try await pid(in: shellPid), sleeper = try await pid(in: sleepPid)
        #expect(isRunning(shell) && isRunning(sleeper))
        let cancelled = ContinuousClock.now
        run.cancel()
        await #expect(throws: CancellationError.self) { try await run.value }
        #expect(ContinuousClock.now - cancelled < .milliseconds(900))
        #expect(await isGone(shell))
        #expect(await isGone(sleeper))
    }

    @Test func aRunThatIgnoresBeingAskedToEndIsKilled() async throws {
        let dir = try ScratchRepo("process-stubborn")
        let alias = "alias.stubborn=!trap '' TERM; echo $$ > shell.pid; while :; do sleep 0.05; done"
        let run = Task { try await dir.repo.run(["-c", alias, "stubborn"], limit: Git.Limit.value) }
        let shell = try await pid(in: dir.root.appendingPathComponent("shell.pid"))
        let cancelled = ContinuousClock.now
        run.cancel()
        await #expect(throws: CancellationError.self) { try await run.value }
        #expect(ContinuousClock.now - cancelled < .seconds(3))
        #expect(await isGone(shell))
    }

    @Test func aTaskCancelledBeforeTheRunStartsRunsNothing() async throws {
        let dir = try ScratchRepo("process-early")
        let marker = dir.root.appendingPathComponent("ran")
        let run = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await dir.repo.run(["-c", "alias.mark=!touch ran", "mark"], limit: Git.Limit.value)
        }
        await #expect(throws: CancellationError.self) { try await run.value }
        #expect(!FileManager.default.fileExists(atPath: marker.path))
    }

    @Test func outputPastTheLimitIsAnErrorNotPartOfTheOutput() async throws {
        let dir = try ScratchRepo("process-limit")
        var big = Data(count: 3 << 20)
        big.withUnsafeMutableBytes { for i in $0.indices { $0[i] = UInt8(truncatingIfNeeded: i &* 2_654_435_761 >> 13) } }
        try big.write(to: dir.root.appendingPathComponent("big.bin"))
        let oid = try dir.git("hash-object", "-w", "big.bin")
        let whole = try await dir.repo.run(["cat-file", "blob", oid], limit: 4 << 20)
        #expect(whole == big)
        let tooSmall = 1 << 20
        do {
            _ = try await dir.repo.run(["cat-file", "blob", oid], limit: tooSmall)
            Issue.record("a run printing past its limit returned")
        } catch let e as GitError {
            #expect(e.reason == .outputTooLarge(limit: tooSmall))
        }
    }

    @Test func aGitThatStopsReadingItsInputFailsTheRunAlone() async throws {
        let dir = try ScratchRepo("process-input")
        try dir.write("a.txt", "a\n")
        let paths = "missing.txt\n" + String(repeating: "a.txt\n", count: 1 << 20)
        await #expect(throws: GitError.self) {
            try await dir.repo.run(["hash-object", "--stdin-paths"], stdin: Data(paths.utf8), limit: Git.Limit.listing)
        }
        let hashed = try await dir.repo.run(["hash-object", "--stdin-paths"], stdin: Data("a.txt\n".utf8), limit: Git.Limit.listing)
        #expect(String(decoding: hashed, as: UTF8.self) == "78981922613b2afb6025042ff6bd878ac1994e85\n")
    }

    @Test func manyRunsAtOnceAllFinishWithTheirOwnOutput() async throws {
        let dir = try ScratchRepo("process-many")
        let outputs = try await withThrowingTaskGroup(of: (Int, String).self) { group in
            for i in 0..<200 {
                group.addTask { (i, String(decoding: try await dir.repo.run(["-c", "alias.say=!sleep 0.2; echo", "say", "\(i)"], limit: Git.Limit.value), as: UTF8.self)) }
            }
            return try await group.reduce(into: [:]) { $0[$1.0] = $1.1 }
        }
        #expect(outputs.count == 200)
        #expect(outputs.allSatisfy { $0.value == "\($0.key)\n" })
    }

    @Test func gitsErrorsComeBackAsItsMessage() async throws {
        let dir = try ScratchRepo("process-error")
        do {
            _ = try await dir.repo.run(["rev-parse", "--verify", "no-such-ref"], limit: Git.Limit.value)
            Issue.record("a failing git returned")
        } catch let e as GitError {
            #expect(e.reason == .failed)
            #expect(e.message.contains("fatal"))
        }
    }
}
