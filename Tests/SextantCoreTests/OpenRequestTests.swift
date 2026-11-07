import Foundation
import Testing
@testable import SextantCore

/// Reads the `sextant` command's arguments in repositories built in the test.
@Suite struct OpenRequestTests {
    /// A repository with a `docs` folder and a `docs` branch, a `src` folder, and a `feature`
    /// branch.
    func repository(_ name: String) throws -> ScratchRepo {
        let r = try ScratchRepo(name)
        try r.write("docs/guide.md", "Guide\n")
        try r.write("src/main.swift", "func run() {}\n")
        try r.write("README.md", "Read me\n")
        try r.commitAll("Base")
        try r.git("branch", "docs")
        try r.git("branch", "feature")
        return r
    }

    func read(_ args: String..., in r: ScratchRepo, from dir: String = "") async throws -> OpenRequest {
        try await OpenRequest.read(args, in: r.root.appendingPathComponent(dir), git: GitIntegrationTests.git)
    }

    func message(_ args: String..., in r: ScratchRepo, from dir: String = "") async -> String? {
        do {
            _ = try await OpenRequest.read(args, in: r.root.appendingPathComponent(dir), git: GitIntegrationTests.git)
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    var top: (ScratchRepo) -> String { { CanonicalPath($0.root).path } }

    @Test func readsALoneNameAsWhicheverOfARevisionAndAPathItNames() async throws {
        let r = try repository("open-lone")
        #expect(try await read("feature", in: r) == OpenRequest(root: top(r), revision: "feature"))
        #expect(try await read("src", in: r) == OpenRequest(root: top(r), revision: nil))
        #expect(await message("docs", in: r)?.contains("both a revision and a path") == true)
        #expect(try await read("./docs", in: r) == OpenRequest(root: top(r), revision: nil))
        #expect(try await read(".", "docs", in: r) == OpenRequest(root: top(r), revision: "docs"))
        #expect(await message("nothing", in: r)?.contains("neither a revision nor a path") == true)
    }

    @Test func opensTheCheckoutAFileIsIn() async throws {
        let r = try repository("open-file")
        #expect(try await read("README.md", in: r) == OpenRequest(root: top(r), revision: nil))
        #expect(try await read("main.swift", "feature", in: r, from: "src") == OpenRequest(root: top(r), revision: "feature"))
        #expect(await message("./missing.txt", in: r)?.contains("no such file or folder") == true)
    }

    @Test func takesTheAppsWordsAndRangesWithASideLeftOut() async throws {
        let r = try repository("open-words")
        for word in ["--staged", "--cached", "staged", "uncommitted", "#12"] {
            #expect(try await read(word, in: r) == OpenRequest(root: top(r), revision: word))
        }
        for range in ["feature..", "..feature", "main...feature", "HEAD~0..docs"] {
            #expect(try await read(range, in: r) == OpenRequest(root: top(r), revision: range))
        }
        #expect(await message("main..gone", in: r) == "unknown revision: gone")
        #expect(await message(".", "gone", in: r) == "unknown revision: gone")
    }

    @Test func saysWhenThePathIsntInARepository() async throws {
        let outside = GitIntegrationTests.root.appendingPathComponent(".build/test-repos/open-outside", isDirectory: true)
        try? FileManager.default.removeItem(at: outside)
        try FileManager.default.createDirectory(at: outside.appendingPathComponent("folder"), withIntermediateDirectories: true)
        try Data("gitdir: /nonexistent\n".utf8).write(to: outside.appendingPathComponent(".git"))
        let messageOutside: String?
        do {
            _ = try await OpenRequest.read(["folder"], in: outside, git: GitIntegrationTests.git)
            messageOutside = nil
        } catch {
            messageOutside = error.localizedDescription
        }
        #expect(messageOutside?.hasPrefix("not a git repository") == true)
    }
}
