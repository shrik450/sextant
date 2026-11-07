import Foundation
import Testing
@testable import SextantCore

/// Reads blobs through the batch reader of real repositories, and checks how long its process
/// lives and what it does with blobs larger than the caller can use.
@Suite struct ObjectReaderTests {
    /// A repository with a small blob, a 3 MB blob and a 17 MB blob, and a linked worktree.
    func repository(_ name: String) throws -> (repo: ScratchRepo, small: String, mid: String, big: String, linked: URL, midData: Data) {
        let r = try ScratchRepo(name)
        try r.write("small.txt", "small\n")
        var mid = Data(count: 3 << 20)
        mid.withUnsafeMutableBytes { for i in $0.indices { $0[i] = UInt8(truncatingIfNeeded: i &* 2_654_435_761 >> 11) } }
        try mid.write(to: r.root.appendingPathComponent("mid.bin"))
        try Data(count: 17 << 20).write(to: r.root.appendingPathComponent("big.bin"))
        try r.commitAll("Blobs")
        let linked = r.root.deletingLastPathComponent().appendingPathComponent(name + "-linked")
        try? FileManager.default.removeItem(at: linked)
        try r.git("worktree", "add", "-q", "--detach", linked.path)
        return (r, try r.git("rev-parse", "HEAD:small.txt"), try r.git("rev-parse", "HEAD:mid.bin"), try r.git("rev-parse", "HEAD:big.bin"), linked, mid)
    }

    func isGone(_ pid: pid_t) async -> Bool {
        for _ in 0..<200 where kill(pid, 0) == 0 { try? await Task.sleep(for: .milliseconds(5)) }
        return kill(pid, 0) != 0
    }

    @Test func checkoutsOfARepositoryShareOneProcess() async throws {
        let f = try repository("objects-shared")
        let git = f.repo.repo, linked = git.forCheckout(f.linked)
        #expect(try await git.blob(f.small) == Data("small\n".utf8))
        let pid = try #require(git.objects.processID)
        #expect(try await linked.blob(f.mid) == f.midData)
        #expect(linked.objects.processID == pid)
        let separate = Git(root: f.linked, executable: GitIntegrationTests.git)
        _ = try await separate.blob(f.small)
        #expect(separate.objects.processID != pid)
    }

    @Test func theProcessEndsWhenIdleAndStartsAgainOnTheNextRead() async throws {
        let f = try repository("objects-idle")
        let reader = ObjectReader(directory: f.repo.root, executable: GitIntegrationTests.git, idleTimeout: .milliseconds(200))
        #expect(try await reader.blob(f.small, limit: 1 << 20) == Data("small\n".utf8))
        let first = try #require(reader.processID)
        try await Task.sleep(for: .milliseconds(600))
        #expect(reader.processID == nil)
        #expect(await isGone(first))
        #expect(try await reader.blob(f.small, limit: 1 << 20) == Data("small\n".utf8))
        #expect(reader.processID != nil && reader.processID != first)
    }

    @Test func theProcessEndsWithTheLastGitHoldingIt() async throws {
        let f = try repository("objects-lifetime")
        var pids: [pid_t] = []
        for _ in 0..<5 {
            let git = Git(root: f.repo.root, executable: GitIntegrationTests.git)
            _ = try await git.forCheckout(f.linked).blob(f.small)
            pids.append(try #require(git.objects.processID))
        }
        for pid in pids { #expect(await isGone(pid)) }
    }

    @Test func aBlobLargerThanTheCallerCanUseIsAnErrorAndLaterReadsStillWork() async throws {
        let f = try repository("objects-limit")
        let git = f.repo.repo
        for oid in [f.mid, f.big] {
            do {
                _ = try await git.blob(oid, limit: 1 << 20)
                Issue.record("a blob past its limit was read")
            } catch let e as GitError {
                #expect(e.reason == .outputTooLarge(limit: 1 << 20))
            }
            #expect(try await git.blob(f.small, limit: 1 << 20) == Data("small\n".utf8))
        }
        #expect(try await git.blob(f.mid, limit: 4 << 20) == f.midData)
        #expect(try await git.blob(f.big, limit: 32 << 20) == Data(count: 17 << 20))
        await #expect(throws: GitError.self) { try await git.blob(String(repeating: "0", count: 39) + "1") }
        #expect(await git.contents(of: "small.txt", in: .commit(try f.repo.git("rev-parse", "HEAD"))) == Data("small\n".utf8))
    }

    @Test func readsAtOnceEachGetTheirOwnBlob() async throws {
        let f = try repository("objects-concurrent")
        let git = f.repo.repo
        let reads = try await withThrowingTaskGroup(of: Bool.self) { group in
            for i in 0..<60 {
                group.addTask { i % 2 == 0 ? try await git.blob(f.small) == Data("small\n".utf8) : try await git.blob(f.mid) == f.midData }
            }
            return try await group.reduce(into: [Bool]()) { $0.append($1) }
        }
        #expect(reads.count == 60 && reads.allSatisfy { $0 })
    }
}
