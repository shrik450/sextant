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
    func conflicted() throws -> ScratchRepo {
        let r = try ScratchRepo("conflicted")
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
}
