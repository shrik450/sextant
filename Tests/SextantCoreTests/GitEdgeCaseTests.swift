import Foundation
import Testing
@testable import SextantCore

/// A repository built for one test, under `.build/test-repos`, by a git with no user
/// configuration.
struct ScratchRepo {
    let root: URL

    init(_ name: String) throws {
        root = GitIntegrationTests.root.appendingPathComponent(".build/test-repos/\(name)", isDirectory: true)
        try? FileManager.default.removeItem(at: root)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try git("init", "-q", "-b", "main")
    }

    var repo: Git { Git(root: root, executable: GitIntegrationTests.git) }

    /// Runs git in the repository with a fixed identity.
    ///
    /// - Parameter allowFailure: Whether a nonzero exit is expected, as from a merge that
    ///   conflicts.
    @discardableResult
    func git(_ args: String..., in dir: String? = nil, stdin: String? = nil, allowFailure: Bool = false) throws -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: GitIntegrationTests.git)
        p.arguments = ["-c", "protocol.file.allow=always", "-c", "merge.conflictStyle=merge"] + args
        p.currentDirectoryURL = dir.map { root.appendingPathComponent($0) } ?? root
        var env = ProcessInfo.processInfo.environment
        env["GIT_CONFIG_GLOBAL"] = "/dev/null"
        env["GIT_CONFIG_NOSYSTEM"] = "1"
        for role in ["AUTHOR", "COMMITTER"] {
            env["GIT_\(role)_NAME"] = "Fixture"
            env["GIT_\(role)_EMAIL"] = "fixture@example.com"
            env["GIT_\(role)_DATE"] = "1700000000 +0000"
        }
        p.environment = env
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        let input = Pipe()
        p.standardInput = stdin == nil ? FileHandle.nullDevice : input
        try p.run()
        if let stdin {
            input.fileHandleForWriting.write(Data(stdin.utf8))
            try input.fileHandleForWriting.close()
        }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        if p.terminationStatus != 0, !allowFailure { throw GitError(message: "git \(args.joined(separator: " ")) exited \(p.terminationStatus)") }
        return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func write(_ path: String, _ text: String) throws {
        let url = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    func link(_ path: String, to target: String) throws {
        try FileManager.default.createSymbolicLink(atPath: root.appendingPathComponent(path).path, withDestinationPath: target)
    }

    func commitAll(_ message: String) throws {
        try git("add", "-A")
        try git("commit", "-q", "-m", message)
    }

    /// The ID git gives a blob with these contents.
    func blobID(_ contents: String) throws -> String { try git("hash-object", "--stdin", stdin: contents) }
}

@Suite struct GitEdgeCaseTests {
    /// A merge stopped on conflicts in `both.txt` (changed on both sides), `added.txt` (added on
    /// both) and `gone.txt` (deleted here, changed there), with clean edits in files around them.
    func conflicted(_ name: String = "conflicted") throws -> ScratchRepo {
        let r = try ScratchRepo(name)
        try r.write("a.txt", "a\n")
        try r.write("both.txt", "one\ntwo\nthree\n")
        try r.write("gone.txt", "base\n")
        try r.write("z.txt", "z\n")
        try r.commitAll("Base")
        try r.git("checkout", "-q", "-b", "theirs")
        try r.write("both.txt", "one\nTHEIRS\nthree\n")
        try r.write("added.txt", "theirs\n")
        try r.write("gone.txt", "changed there\n")
        try r.commitAll("Theirs")
        try r.git("checkout", "-q", "main")
        try r.write("both.txt", "one\nOURS\nthree\n")
        try r.write("added.txt", "ours\n")
        try FileManager.default.removeItem(at: r.root.appendingPathComponent("gone.txt"))
        try r.commitAll("Ours")
        try r.git("merge", "-q", "theirs", allowFailure: true)
        try r.write("a.txt", "a\nmore a\n")
        try r.write("z.txt", "z\nmore z\n")
        return r
    }

    @Test func unmergedPathsKeepEveryOtherFileWithItsOwnPatch() async throws {
        let r = try conflicted()
        for target in [Target.unstaged, .worktree(since: nil), .staged] {
            let files = try await r.repo.diff(target)
            let byPath = Dictionary(files.map { ($0.path, $0) }, uniquingKeysWith: { a, _ in a })
            #expect(files.count == byPath.count, "\(target): one entry per path")
            if target != .staged {
                #expect(byPath["a.txt"]?.hunks.flatMap(\.lines).filter { $0.kind == .added }.map(\.text) == ["more a"], "\(target)")
                #expect(byPath["z.txt"]?.hunks.flatMap(\.lines).filter { $0.kind == .added }.map(\.text) == ["more z"], "\(target)")
            }
            for path in ["both.txt", "added.txt"] {
                let file = try #require(byPath[path], "\(target) \(path)")
                if target == .staged {
                    #expect(file.change.status == "U" && file.hunks.isEmpty, "\(target) \(path)")
                } else {
                    let added = file.hunks.flatMap(\.lines).filter { $0.kind == .added }.map(\.text)
                    #expect(added.first == "<<<<<<< HEAD" && added.last == ">>>>>>> theirs", "\(target) \(path)")
                }
            }
        }
        let unstaged = try await r.repo.diff(.unstaged)
        let both = try #require(unstaged.first { $0.path == "both.txt" })
        #expect(both.change.status == "U")
        #expect(both.change.oldOid == (try r.blobID("one\nOURS\nthree\n")))
        let old = try await r.repo.oldLines(of: both)
        #expect(wholeFile(both.hunks, oldLines: old).filter { $0.kind != .added }.map(\.text) == old)
        #expect(unstaged.first { $0.path == "gone.txt" }?.change.status == "U")
    }

    @Test func statusCountsWhatIsUncommittedAndFailsRatherThanReadingClean() async throws {
        let r = try conflicted("conflicted-status")
        let status = try await r.repo.status()
        #expect(status.conflicts == ["both.txt", "added.txt", "gone.txt"])
        #expect(status.count == 5)
        try Data("not an index".utf8).write(to: r.root.appendingPathComponent(".git/index"))
        await #expect(throws: GitError.self) { try await r.repo.status() }
    }
}

extension GitEdgeCaseTests {
    /// A worktree holding what `git hash-object` can't hash: symbolic links (one dangling, one to
    /// a folder), a submodule moved to another commit, and an untracked repository.
    func unhashable() throws -> (repo: ScratchRepo, submoduleHead: String) {
        let upstream = try ScratchRepo("unhashable-upstream")
        try upstream.write("u.txt", "u\n")
        try upstream.commitAll("Upstream")
        let r = try ScratchRepo("unhashable")
        try r.write("a.txt", "a\n")
        try r.commitAll("A")
        try r.git("submodule", "add", "-q", upstream.root.path, "sub")
        try r.commitAll("Sub")
        try r.write("a.txt", "a\nmore\n")
        try r.write("sub/u.txt", "u\nmoved\n")
        try r.git("commit", "-q", "-am", "Move", in: "sub")
        try r.link("good", to: "a.txt")
        try r.link("dangling", to: "nowhere")
        try FileManager.default.createDirectory(at: r.root.appendingPathComponent("dir"), withIntermediateDirectories: true)
        try r.write("dir/in.txt", "in\n")
        try r.link("dirlink", to: "dir")
        let nested = r.root.appendingPathComponent("nested")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try r.git("init", "-q", in: "nested")
        try r.write("nested/n.txt", "n\n")
        try r.git("add", "-A", in: "nested")
        try r.git("commit", "-q", "-m", "Nested", in: "nested")
        return (r, try r.git("rev-parse", "HEAD", in: "sub"))
    }

    @Test func hashesWhatGitWouldStoreWithoutFailingOnWhatItCant() async throws {
        let (r, subHead) = try unhashable()
        let edited = try r.blobID("a\nmore\n")
        let hashed = try await r.repo.hashObjects(["a.txt", "good", "dangling", "dirlink", "dir", "nested", "sub", "missing"])
        #expect(hashed == [edited, try r.blobID("a.txt"), try r.blobID("nowhere"), try r.blobID("dir"), nil, nil, nil, nil])

        let files = try await r.repo.diff(.worktree(since: nil))
        let byPath = Dictionary(uniqueKeysWithValues: files.map { ($0.path, $0.change) })
        #expect(Set(byPath.keys) == ["a.txt", "good", "dangling", "dirlink", "dir/in.txt", "nested", "sub"])
        #expect(byPath["a.txt"]?.newOid == edited)
        for (link, target) in [("good", "a.txt"), ("dangling", "nowhere"), ("dirlink", "dir")] {
            let id = try r.blobID(target)
            #expect(byPath[link]?.newMode == "120000" && byPath[link]?.newOid == id, "\(link)")
        }
        #expect(byPath["sub"]?.newMode == "160000" && byPath["sub"]?.newOid == subHead)
        #expect(byPath["nested"]?.isUntracked == true && byPath["nested"]?.newMode == "160000")
    }

    @Test func untrackedFilesThatCantBeReadDontFailTheDiff() async throws {
        let r = try ScratchRepo("unreadable")
        try r.write("b.txt", "b\n")
        try r.commitAll("B")
        try r.write("b.txt", "b\nmore\n")
        try r.write("locked.txt", "secret\n")
        #expect(chmod(r.root.appendingPathComponent("locked.txt").path, 0) == 0)
        let files = try await r.repo.diff(.worktree(since: nil))
        #expect(files.map(\.path) == ["b.txt"])
        #expect(files.first?.change.newOid == (try r.blobID("b\nmore\n")))
    }

    @Test func filesDeletedWhileDiffingDontFailIt() async throws {
        let r = try ScratchRepo("vanishing")
        try r.write("a.txt", "a\n")
        try r.commitAll("A")
        let names = (0..<2000).map { "f\($0).txt" }
        for round in 0..<10 {
            for n in names { try r.write(n, "\(round)\n") }
            let deleting = Task.detached {
                for n in names.shuffled() {
                    try? FileManager.default.removeItem(at: r.root.appendingPathComponent(n))
                    usleep(20)
                }
            }
            _ = try await r.repo.diff(.worktree(since: nil))
            await deleting.value
        }
    }
}

extension GitEdgeCaseTests {
    @Test func anAddedFileHasNoOldSideToFillIn() async throws {
        let r = try ScratchRepo("added")
        try r.write("a.txt", "a\n")
        try r.commitAll("A")
        try r.write("b.txt", "one\ntwo\nthree\n")
        try r.commitAll("B")
        try r.write("untracked.txt", "u1\nu2\n")
        let committed = try await r.repo.diff(.commit(try r.git("rev-parse", "HEAD")))
        let untracked = try await r.repo.diff(.worktree(since: nil))
        for file in committed + untracked {
            #expect(file.change.isAdded && file.hunksAreWholeFile, "\(file.path)")
            let old = try await r.repo.oldLines(of: file)
            #expect(old.isEmpty, "\(file.path)")
            #expect(wholeFile(file.hunks, oldLines: old) == file.hunks.flatMap(\.lines), "\(file.path)")
        }
        #expect(committed.map(\.path) == ["b.txt"] && untracked.map(\.path) == ["untracked.txt"])
    }
}

extension GitEdgeCaseTests {
    @Test func readsWorktreeFilesAsGitStoresThemWithinTheLimit() async throws {
        let r = try ScratchRepo("worktree-reads")
        try r.write("a.txt", "a\n")
        try r.commitAll("A")
        try Data(count: 64).write(to: r.root.appendingPathComponent("big.bin"))
        try r.write("exact.txt", String(repeating: "x", count: 32))
        try r.link("good", to: "a.txt")
        try r.link("biglink", to: "big.bin")
        try r.link("dangling", to: "nowhere")
        try FileManager.default.createDirectory(at: r.root.appendingPathComponent("dir"), withIntermediateDirectories: true)
        #expect(mkfifo(r.root.appendingPathComponent("fifo").path, 0o644) == 0)
        let git = r.repo
        #expect(git.readWorktreeFile("a.txt") == Data("a\n".utf8))
        #expect(git.readWorktreeFile("exact.txt", limit: 32) == Data(String(repeating: "x", count: 32).utf8))
        #expect(git.readWorktreeFile("big.bin", limit: 32) == nil)
        #expect(git.readWorktreeFile("good") == Data("a.txt".utf8))
        #expect(git.readWorktreeFile("biglink", limit: 32) == Data("big.bin".utf8))
        #expect(git.readWorktreeFile("dangling") == Data("nowhere".utf8))
        #expect(git.readWorktreeFile("dir") == nil)
        #expect(git.readWorktreeFile("fifo") == nil)
        #expect(git.readWorktreeFile("missing") == nil)

        let good = try #require(try await git.diff(.worktree(since: nil)).first { $0.path == "good" })
        #expect(good.hunks.flatMap(\.lines).map(\.text) == ["a.txt"])
        #expect(good.hunks.last?.lines.last?.noNewline == true)
    }
}

extension GitEdgeCaseTests {
    @Test func crlfLinesReadAlikeFromPatchesAndBlobs() async throws {
        let r = try ScratchRepo("crlf")
        try r.write("dos.txt", "one\r\ntwo\r\nthree\r\nfour\r\nfive\r\nsix\r\nseven\r\neight\r\n")
        try r.commitAll("DOS")
        try r.write("dos.txt", "one\r\ntwo\r\nthree\r\nfour\r\nFIVE\r\nsix\r\nseven\r\neight\r\nnine\r\n")
        let file = try #require(try await r.repo.diff(.worktree(since: nil)).first)
        #expect(file.hunks.flatMap(\.lines).allSatisfy { !$0.text.hasSuffix("\r") })
        let old = try await r.repo.oldLines(of: file)
        let all = wholeFile(file.hunks, oldLines: old)
        #expect(all.filter { $0.kind != .added }.map(\.text) == old)
        #expect(all.filter { $0.kind != .deleted }.map(\.text) == splitLines(try #require(r.repo.readWorktreeFile("dos.txt"))))
    }
}

extension GitEdgeCaseTests {
    @Test func pathsHoldingNewlinesHashAndSearch() async throws {
        let r = try ScratchRepo("newline-paths")
        let tracked = "new\nline.txt", untracked = "un\ntracked.txt", quoted = "\"quoted\".txt"
        try r.write(tracked, "needle one\n")
        try r.commitAll("Tracked")
        try r.write(tracked, "needle two\n")
        try r.write(untracked, "needle three\n")
        try r.write(quoted, "needle four\n")
        let ids = [tracked: try r.blobID("needle two\n"), untracked: try r.blobID("needle three\n"), quoted: try r.blobID("needle four\n")]

        let files = try await r.repo.diff(.worktree(since: nil))
        #expect(Dictionary(uniqueKeysWithValues: files.map { ($0.path, $0.change.newOid) }) == ids)
        let blobs = try await r.repo.blobs(in: .worktree)
        #expect(Dictionary(uniqueKeysWithValues: blobs.map { ($0.path, $0.oid) }) == ids)
        let found = try await r.repo.grep("needle", in: .worktree, word: true, ignoreCase: false)
        #expect(Set(found.map(\.path)) == Set(ids.keys))
        #expect(found.allSatisfy { $0.line == 1 && $0.column == 1 && $0.text.hasPrefix("needle ") })
    }
}

extension GitEdgeCaseTests {
    @Test func listsBranchesNamedHEADButNotSymbolicRefs() async throws {
        let r = try ScratchRepo("branch-named-head")
        try r.write("a.txt", "a\n")
        try r.commitAll("A")
        try r.git("branch", "feature/HEAD")
        try r.git("update-ref", "refs/remotes/origin/main", "HEAD")
        try r.git("update-ref", "refs/remotes/origin/topic/HEAD", "HEAD")
        try r.git("symbolic-ref", "refs/remotes/origin/HEAD", "refs/remotes/origin/main")
        let names = Set(await r.repo.branches(comparedWith: "main").map(\.name))
        #expect(names == ["main", "feature/HEAD", "origin/main", "origin/topic/HEAD"])
    }

    @Test func summarizesACRLFMessageByItsFirstLine() async throws {
        let r = try ScratchRepo("crlf-message")
        try r.write("a.txt", "a\n")
        try r.commitAll("A")
        let oid = try r.git("commit-tree", "HEAD^{tree}", "-p", "HEAD", stdin: "Subject line\r\n\r\nBody line\r\n")
        let detail = try await r.repo.commitDetail(oid)
        #expect(detail.summary == "Subject line")
        #expect(detail.body == "Body line")
    }

    @Test func aRunOfCommitsPastTheListedOnesDiffsFromItsOwnParent() async throws {
        let r = try ScratchRepo("long-branch")
        try r.write("base.txt", "base\n")
        try r.commitAll("Base")
        try r.git("checkout", "-q", "-b", "long")
        var stream = ""
        for i in 0..<1005 {
            stream += "commit refs/heads/long\ncommitter Fixture <fixture@example.com> \(1700000000 + i) +0000\ndata 3\nc\(i % 10)\n"
            stream += (i == 0 ? "from refs/heads/long^0\n" : "") + "M 100644 inline f\(i).txt\ndata 2\n\(i % 10)\n\n"
        }
        try r.git("fast-import", "--quiet", "--force", stdin: stream)
        let oldest = try r.git("rev-parse", "long~1004"), second = try r.git("rev-parse", "long~1003")
        let resolved = try await Resolver(git: r.repo).resolve(Review(subject: .branch("long"), base: "main", scope: .commits(newest: second, oldest: oldest)),
                                                               worktrees: [], pullRequests: [])
        #expect(resolved.commits.count == 1000 && !resolved.commits.contains { $0.oid == oldest })
        #expect(resolved.target == .range(base: try r.git("rev-parse", "main"), head: second))
        #expect(try await resolved.git.diff(resolved.target).map(\.path) == ["f0.txt", "f1.txt"])
    }
}

extension GitEdgeCaseTests {
    @Test func aFileRenamedOrMadeExecutableKeepsItsContentsToRead() async throws {
        let r = try ScratchRepo("rename-mode")
        try r.write("old.txt", "one\ntwo\nthree\n")
        try r.write("run.sh", "echo hi\n")
        try r.write("empty.txt", "")
        try r.commitAll("Files")
        try r.git("mv", "old.txt", "new.txt")
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: r.root.appendingPathComponent("run.sh").path)
        try r.write("added-empty.txt", "")
        try r.commitAll("Rename, chmod and an empty file")
        let diffs = try await r.repo.diff(.commit(try r.git("rev-parse", "HEAD")))
        let renamed = try #require(diffs.first { $0.path == "new.txt" })
        let chmodded = try #require(diffs.first { $0.path == "run.sh" })
        let empty = try #require(diffs.first { $0.path == "added-empty.txt" })
        #expect(renamed.change.isRename && renamed.hunks.isEmpty && chmodded.hunks.isEmpty && empty.hunks.isEmpty)
        #expect(!renamed.hunksAreWholeFile)
        #expect(!chmodded.hunksAreWholeFile)
        #expect(empty.hunksAreWholeFile)
        let whole = wholeFile(renamed.hunks, oldLines: try await r.repo.oldLines(of: renamed))
        #expect(whole == ["one", "two", "three"].enumerated().map { DiffLine(kind: .context, oldNo: $0.offset + 1, newNo: $0.offset + 1, text: $0.element) })
        #expect(wholeFile(chmodded.hunks, oldLines: try await r.repo.oldLines(of: chmodded)).map(\.text) == ["echo hi"])
    }
}
