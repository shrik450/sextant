import Foundation
import Testing
@testable import RevueCore

/// Runs the git layer against a real repository built by Tests/make-fixture.sh.
@Suite(.serialized) struct GitIntegrationTests {
    static let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    static let fixture = root.appendingPathComponent(".build/test-fixture")
    static let git: String = {
        for dir in (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":") where FileManager.default.isExecutableFile(atPath: "\(dir)/git") {
            return "\(dir)/git"
        }
        return "/usr/bin/git"
    }()

    static let ready: Bool = {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/bash")
        p.arguments = [root.appendingPathComponent("Tests/make-fixture.sh").path, fixture.path]
        p.standardOutput = FileHandle.nullDevice
        try? p.run()
        p.waitUntilExit()
        return p.terminationStatus == 0
    }()

    var repo: Git { Git(root: Self.fixture, executable: Self.git) }

    @Test func uncommittedIncludesUntrackedAndHashesWorktree() async throws {
        #expect(Self.ready)
        let files = try await repo.diff(.worktree(since: nil))
        let paths = files.map(\.path)
        #expect(paths == ["dir with space/file name.txt", "main.go", "notes.md", "scripts/build.py", "src/lib.rs"])
        #expect(files.allSatisfy { $0.change.newOid != zeroOid })
        let notes = files.first { $0.path == "notes.md" }!
        #expect(notes.change.isUntracked && notes.additions == 3)
        let hashed = try await repo.hashObjects(["notes.md"])
        #expect(hashed == [notes.change.newOid])
    }

    @Test func stagedAndUnstagedSplitTheWorktree() async throws {
        #expect(Self.ready)
        let staged = try await repo.diff(.staged).map(\.path)
        let unstaged = try await repo.diff(.unstaged).map(\.path)
        #expect(staged == ["main.go"])
        #expect(unstaged == ["dir with space/file name.txt", "notes.md", "scripts/build.py", "src/lib.rs"])
    }

    @Test func commitDiffsCoverRenameModeBinaryAndDelete() async throws {
        #expect(Self.ready)
        let commits = try await repo.log("main", skip: 0, count: 50)
        let move = try #require(commits.first { $0.subject.hasPrefix("Move math") })
        let files = try await repo.diff(.commit(move.oid))
        let byPath = Dictionary(uniqueKeysWithValues: files.map { ($0.path, $0) })
        #expect(byPath["src/math.c"]?.change.isRename == true)
        #expect(byPath["src/math.c"]?.change.oldPath == "old-name.c")
        #expect(byPath["docs/logo.png"]?.isBinary == true)
        #expect(byPath["docs/nonl.txt"]?.change.isDeleted == true)
        #expect(byPath["docs/nonl.txt"]?.hunks.first?.lines.last?.noNewline == true)
        #expect(byPath["deploy.sh"]?.change.newMode == "100755")
        #expect(Set(move.changes.map(\.reviewKey)) == Set(files.map(\.change.reviewKey)))
    }

    @Test func rootAndMergeCommits() async throws {
        #expect(Self.ready)
        let commits = try await repo.log("main", skip: 0, count: 50)
        let root = try #require(commits.last)
        #expect(root.parents.isEmpty)
        #expect(try await repo.diff(.commit(root.oid)).count == 13)
        let merge = try #require(commits.first { $0.isMerge })
        let files = try await repo.diff(.commit(merge.oid))
        #expect(files.map(\.path) == ["src/search.swift"])
        #expect(merge.changes.map(\.path) == ["src/search.swift"])
        #expect(merge.refs.contains("main") && merge.refs.contains("v1.0"))
    }

    @Test func wholeFileReproducesBothSides() async throws {
        #expect(Self.ready)
        for target in [Target.worktree(since: nil), .staged, .unstaged] {
            for file in try await repo.diff(target) where !file.change.isAdded && !file.isBinary && !file.change.isDeleted {
                let old = try await repo.oldLines(of: file)
                let all = wholeFile(file.hunks, oldLines: old)
                #expect(all.filter { $0.kind != .added }.map(\.text) == old, "\(file.path) old side")
                let newData = target == .staged ? await repo.contents(of: file.path, in: .index) : repo.readWorktreeFile(file.path)
                #expect(all.filter { $0.kind != .deleted }.map(\.text) == splitLines(try #require(newData)), "\(file.path) new side")
            }
        }
    }

    @Test func pagingAndStashes() async throws {
        #expect(Self.ready)
        let a = try await repo.log("HEAD", skip: 0, count: 3)
        let b = try await repo.log("HEAD", skip: 3, count: 3)
        #expect(a.count == 3 && b.count == 3)
        #expect(Set(a.map(\.oid)).isDisjoint(with: b.map(\.oid)))
        let stashes = await repo.stashes()
        #expect(stashes.count == 1 && stashes[0].ref == "stash@{0}")
        let files = try await repo.diff(.stash(stashes[0].oid))
        #expect(files.map(\.path) == ["README.md"])
    }

    @Test func filesInEverySnapshot() async throws {
        #expect(Self.ready)
        let head = try #require(await repo.head())
        let committed = try await repo.files(in: .commit(head))
        #expect(committed.contains("src/math.c") && !committed.contains("notes.md") && !committed.contains("old-name.c"))
        let worktree = try await repo.files(in: .worktree)
        #expect(worktree.contains("notes.md") && worktree.contains("dir with space/file name.txt"))
        #expect(Set(worktree).count == worktree.count)
        let index = try await repo.files(in: .index)
        #expect(!index.contains("notes.md") && index.contains("main.go"))
    }

    @Test func contentsDifferPerSnapshot() async throws {
        #expect(Self.ready)
        let head = try #require(await repo.head())
        func text(_ s: Snapshot) async -> String? { await repo.contents(of: "main.go", in: s).map { String(decoding: $0, as: UTF8.self) } }
        #expect(await text(.commit(head))?.contains("\"hello\")") == true)
        #expect(await text(.index)?.contains("hello, world") == true)
        #expect(await text(.worktree)?.contains("hello, world") == true)
        #expect(await repo.contents(of: "notes.md", in: .commit(head)) == nil)
    }

    @Test func batchReadsMatchOneOffReads() async throws {
        #expect(Self.ready)
        let head = try #require(await repo.head())
        let paths = try await repo.files(in: .commit(head))
        let reads = await withTaskGroup(of: (String, Data?, Data?).self) { group in
            for p in paths {
                group.addTask {
                    let batched = await repo.contents(of: p, in: .commit(head))
                    let oneOff = try? await repo.run(["cat-file", "blob", head + ":" + p])
                    return (p, batched, oneOff)
                }
            }
            return await group.reduce(into: []) { $0.append($1) }
        }
        #expect(reads.count == paths.count)
        for (p, batched, oneOff) in reads { #expect(batched != nil && batched == oneOff, "\(p)") }
        let tree = try await repo.run(["rev-parse", head + "^{tree}"])
        await #expect(throws: GitError.self) { try await repo.blob(String(decoding: tree, as: UTF8.self).trimmingCharacters(in: .newlines)) }
        await #expect(throws: GitError.self) { try await repo.blob(String(repeating: "0", count: 39) + "1") }
        #expect(await repo.contents(of: "src", in: .commit(head)) == nil)
    }

    @Test func grepFindsWholeWordsPerSnapshot() async throws {
        #expect(Self.ready)
        let head = try #require(await repo.head())
        let inHead = try await repo.grep("peek", in: .commit(head), word: true, ignoreCase: false)
        #expect(inHead.contains { $0.path == "src/parser.swift" && $0.text.contains("func peek(") })
        #expect(inHead.allSatisfy { !$0.path.contains(":") })
        let m = try #require(inHead.first { $0.text.contains("func peek(") })
        #expect(Array(Array(m.text.utf8)[(m.column - 1)...].prefix(4)) == Array("peek".utf8))
        #expect(try await repo.grep("Untracked", in: .worktree, word: true, ignoreCase: false).map(\.path) == ["notes.md"])
        #expect(try await repo.grep("Untracked", in: .commit(head), word: true, ignoreCase: false).isEmpty)
        #expect(try await repo.grep("zzzz-no-such-thing", in: .index, word: false, ignoreCase: false).isEmpty)
        #expect(try await repo.grep("pee", in: .commit(head), word: true, ignoreCase: false).isEmpty)
    }

    @Test func blameAttributesLines() async throws {
        #expect(Self.ready)
        let head = try #require(await repo.head())
        let committed = try await repo.blame("src/parser.swift", in: .commit(head))
        let source = splitLines(try #require(await repo.contents(of: "src/parser.swift", in: .commit(head))))
        #expect(committed.lines.count == source.count)
        let peek = try #require(source.firstIndex { $0.contains("func peek(") })
        #expect(committed.commit(forLine: peek)?.summary == "Teach the parser to peek ahead")
        #expect(committed.commit(forLine: 0)?.summary == "Initial commit")
        #expect(committed.commit(forLine: 0)?.author == "Ada Lovelace")
        let worktree = try await repo.blame("scripts/build.py", in: .worktree)
        #expect(worktree.lines.indices.contains { worktree.commit(forLine: $0)?.isUncommitted == true })
        let staged = try await repo.blame("main.go", in: .index)
        #expect(staged.lines.indices.contains { staged.commit(forLine: $0)?.isUncommitted == true })
    }

    @Test func historyFollowsRenames() async throws {
        #expect(Self.ready)
        let commits = try await repo.history(of: "src/math.c", from: "HEAD", count: 50)
        #expect(commits.map(\.subject) == ["Move math into src, make deploy executable", "Initial commit"])
    }
}
