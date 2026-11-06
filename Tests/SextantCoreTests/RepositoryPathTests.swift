import Foundation
import Testing
@testable import SextantCore

/// Runs path canonicalization and change filtering against repositories built in the test,
/// reached through a symbolic link, and the changes FSEvents reports in them.
@Suite struct RepositoryPathTests {
    /// A repository with a linked worktree, and a symbolic link to the repository.
    func linked(_ name: String) throws -> (repo: ScratchRepo, link: URL) {
        let r = try ScratchRepo(name)
        try r.write("a.txt", "a\n")
        try r.write("sub/b.txt", "b\n")
        try r.commitAll("A")
        let wt = r.root.deletingLastPathComponent().appendingPathComponent("\(name)-wt")
        try? FileManager.default.removeItem(at: wt)
        try r.git("worktree", "prune")
        try r.git("worktree", "add", "-q", wt.path)
        let link = r.root.deletingLastPathComponent().appendingPathComponent("\(name)-link")
        try? FileManager.default.removeItem(at: link)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: r.root)
        return (r, link)
    }

    @Test func canonicalPathsResolveLinksAndPrivateAsRealpathDoes() throws {
        #expect(CanonicalPath(path: "/tmp").path == "/private/tmp")
        #expect(CanonicalPath(path: "/tmp/not-there-\(UUID())/x").path.hasPrefix("/private/tmp/not-there-"))
        let (r, link) = try linked("canonical")
        let real = CanonicalPath(r.root)
        #expect(CanonicalPath(link) == real)
        #expect(CanonicalPath(link.appendingPathComponent("sub/../a.txt")).path == real.path + "/a.txt")
        #expect(CanonicalPath(link.appendingPathComponent("missing/file")).path == real.path + "/missing/file")
        #expect(real.components(of: real.path + "/sub/b.txt") == ["sub", "b.txt"])
        #expect(real.components(of: real.path + "-wt/a.txt") == nil)
    }

    @Test func aRepositoryReachedThroughALinkIsNamedAsGitNamesIt() async throws {
        let (r, link) = try linked("located")
        let loc = try await Git.locate(link.appendingPathComponent("sub"), executable: GitIntegrationTests.git)
        let worktrees = await r.repo.worktrees()
        #expect(loc.root == worktrees.first?.root)
        #expect(loc.commonDir.path == CanonicalPath(r.root).path + "/.git")
        let fromWorktree = try await Git.locate(try #require(worktrees.last).root.url, executable: GitIntegrationTests.git)
        #expect(fromWorktree.commonDir == loc.commonDir)
    }

    @Test func changesReportedUnderALinkedRepositoryAreToldApart() async throws {
        let (r, link) = try linked("watched")
        let loc = try await Git.locate(link, executable: GitIntegrationTests.git)
        let changes = RepositoryChanges(commonDir: loc.commonDir)
        let seen = Paths()
        let watcher = FileWatcher(paths: [loc.commonDir, loc.root], latency: 0.05, queue: DispatchQueue(label: "watched")) { seen.add($0) }
        try await Task.sleep(for: .milliseconds(300))

        let common = loc.commonDir.url
        let own = common.appendingPathComponent("sextant/reviewed.json")
        try FileManager.default.createDirectory(at: own.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("[]".utf8).write(to: own)
        let worktreeLog = common.appendingPathComponent("worktrees/watched-wt/logs/HEAD")
        try Data("log\n".utf8).append(to: worktreeLog)
        try r.write("a.txt", "changed\n")
        let edited = loc.root.path + "/a.txt"
        for _ in 0..<100 where !seen.all.contains(edited) { try await Task.sleep(for: .milliseconds(50)) }
        withExtendedLifetime(watcher) {}

        let all = seen.all
        #expect(all.contains(edited))
        #expect(changes.matter(edited))
        for path in [own.path, worktreeLog.path].map({ CanonicalPath(path: $0).path }) {
            #expect(all.contains(path), "FSEvents reports \(path) as named")
            #expect(!changes.matter(path), "\(path)")
        }
    }

    @Test func lockFilesMatterOnlyOutsideGitDirectories() async throws {
        let (r, _) = try linked("locks")
        let loc = try await Git.locate(r.root, executable: GitIntegrationTests.git)
        let changes = RepositoryChanges(commonDir: loc.commonDir)
        let seen = Paths()
        let watcher = FileWatcher(paths: [loc.commonDir, loc.root], latency: 0.05, queue: DispatchQueue(label: "locks")) { seen.add($0) }
        try await Task.sleep(for: .milliseconds(300))
        try r.write("Cargo.lock", "version = 4\n")
        try r.git("add", "Cargo.lock")
        let lockfile = loc.root.path + "/Cargo.lock", indexLock = loc.commonDir.path + "/index.lock"
        for _ in 0..<100 where !(seen.all.contains(lockfile) && seen.all.contains(indexLock)) { try await Task.sleep(for: .milliseconds(50)) }
        withExtendedLifetime(watcher) {}
        #expect(seen.all.contains(lockfile) && seen.all.contains(indexLock))
        #expect(changes.matter(lockfile))
        #expect(!changes.matter(indexLock))
    }

    @Test func gitsBookkeepingAndSextantsFilesDontMatter() {
        let changes = RepositoryChanges(commonDir: CanonicalPath(path: "/r/.git"))
        for path in ["/r/.git/objects/ab/cdef", "/r/.git/logs/HEAD", "/r/.git/lfs/tmp/x", "/r/.git/sextant/notes.json",
                     "/r/.git/worktrees/wt/logs/HEAD", "/r/.git/index.lock", "/r/.git/refs/heads/main.lock",
                     "/r/.git/worktrees/wt/index.lock", "/r/vendor/.git/index.lock", "/r/sub/.git/objects/pack/p"] {
            #expect(!changes.matter(path), "\(path)")
        }
        for path in ["/r/a.txt", "/r/.git/index", "/r/.git/HEAD", "/r/.git/refs/heads/main", "/r/.git/worktrees/wt/index",
                     "/r/.git/worktrees/wt/HEAD", "/r/.git/objectsmith", "/wt/a.txt", "/r/Cargo.lock", "/r/nix/flake.lock",
                     "/wt/web/yarn.lock", "/r/.github/x.lock"] {
            #expect(changes.matter(path), "\(path)")
        }
    }
}

/// Paths gathered from a watcher on another queue.
final class Paths: @unchecked Sendable {
    private let lock = NSLock()
    private var paths: [String] = []
    var all: [String] { lock.withLock { paths } }
    func add(_ more: [String]) { lock.withLock { paths += more } }
}

extension Data {
    func append(to url: URL) throws {
        let h = try FileHandle(forWritingTo: url)
        defer { try? h.close() }
        try h.seekToEnd()
        try h.write(contentsOf: self)
    }
}
