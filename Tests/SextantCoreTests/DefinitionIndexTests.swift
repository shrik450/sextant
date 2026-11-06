import Foundation
import Testing
@testable import SextantCore

/// Runs the definition index and content analysis against a repository with more files that
/// define a name than lookups used to read.
@Suite(.serialized) struct DefinitionIndexTests {
    static let dir = GitIntegrationTests.root.appendingPathComponent(".build/test-definitions-repo")
    static let cache = GitIntegrationTests.root.appendingPathComponent(".build/test-definitions-repo.json")

    static let ready: Bool = {
        let script = """
        set -euo pipefail
        rm -rf "$1" && mkdir -p "$1/many" && cd "$1"
        export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
        export GIT_AUTHOR_NAME=Ada GIT_AUTHOR_EMAIL=ada@example.com GIT_COMMITTER_NAME=Ada GIT_COMMITTER_EMAIL=ada@example.com
        git init -q -b main .
        for i in $(seq 1 250); do
          printf 'func shared() -> Int {\\n    let local = %d\\n    return local\\n}\\n' "$i" > "many/f$i.swift"
        done
        printf 'let x = shared()\\n' > use.swift
        printf 'fn main() {}\\n' > same.rs
        cp same.rs same.go
        ln -s use.swift link.swift
        git add -A
        git commit -q -m Files
        """
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/bash")
        p.arguments = ["-c", script, "make-repo", dir.path]
        p.standardOutput = FileHandle.nullDevice
        try? p.run()
        p.waitUntilExit()
        return p.terminationStatus == 0
    }()

    var repo: Git { Git(root: Self.dir, executable: GitIntegrationTests.git) }

    func head() async throws -> Snapshot { .commit(try #require(await repo.resolve("HEAD"))) }

    @Test func lookUpFindsDefinitionsInEveryFileThatUsesTheName() async throws {
        #expect(Self.ready)
        let index = DefinitionIndex(analysis: ContentAnalysis(cache: nil))
        let shared = try await index.lookUp("shared", in: try await head(), git: repo)
        #expect(shared.matches.count == 251)
        #expect(shared.definitions.count == 250)
        #expect(shared.definitions.allSatisfy { $0.text == "func shared() -> Int {" && $0.line == 1 })
        let local = try await index.lookUp("local", in: .worktree, git: repo)
        #expect(local.definitions.count == 250)
        #expect(local.definitions.allSatisfy { $0.line == 2 })
    }

    @Test func lookupsAndReadersFillTheIndexGoToAnythingReads() async throws {
        #expect(Self.ready)
        try? FileManager.default.removeItem(at: Self.cache)
        let snapshot = try await head()
        let index = DefinitionIndex(analysis: ContentAnalysis(cache: Self.cache))
        _ = try await index.lookUp("shared", in: snapshot, git: repo)
        let toParse = ParseCount()
        let all = try await index.definitions(in: snapshot, git: repo) { _, total in toParse.set(total) }
        #expect(toParse.value == 2)
        #expect(all.contains { $0.name == "shared" && $0.path == "many/f1.swift" && $0.inOutline })
        #expect(all.contains { $0.name == "local" && $0.path == "many/f1.swift" && !$0.inOutline })

        let edited = Self.dir.appendingPathComponent("many/f1.swift")
        let original = try Data(contentsOf: edited)
        defer { try? original.write(to: edited) }
        let changed = Data("func shared() -> Int {\n    1\n}\n\nfunc added() {}\n".utf8)
        try changed.write(to: edited)
        let swift = try #require(SyntaxRuntime.shared?.language(forPath: "a.swift"))
        let read = await index.analysis.analysis(of: splitLines(changed), oid: blobID(of: changed), language: swift, definitions: true)
        #expect(read.definitions?.map(\.name) == ["shared", "added"])
        toParse.set(0)
        let inWorktree = try await index.definitions(in: .worktree, git: repo) { _, total in toParse.set(total) }
        #expect(toParse.value == 0)
        #expect(inWorktree.contains { $0.name == "added" && $0.path == "many/f1.swift" && $0.line == 5 })

        await index.analysis.flush()
        let relaunched = DefinitionIndex(analysis: ContentAnalysis(cache: Self.cache))
        _ = try await relaunched.definitions(in: snapshot, git: repo) { _, total in toParse.set(total) }
        #expect(toParse.value == 0)
    }

    @Test func eachGrammarParsesTheSameContentsItsOwnWay() async throws {
        #expect(Self.ready)
        let all = try await DefinitionIndex(analysis: ContentAnalysis(cache: nil)).definitions(in: try await head(), git: repo)
        #expect(all.contains { $0.name == "main" && $0.path == "same.rs" })
        #expect(!all.contains { $0.name == "main" && $0.path == "same.go" })
        #expect(!all.contains { $0.path == "link.swift" })
    }

    @Test func analysisColoursCodeUnderLongCommentsAndIgnoresCR() async throws {
        let analysis = ContentAnalysis(cache: nil)
        let swift = try #require(SyntaxRuntime.shared?.language(forPath: "a.swift"))
        let lines = ["/**", " * Four", " * lines", " */", "func f() {}"]
        let whole = await analysis.analysis(of: lines, oid: blobID(of: Data(lines.joined(separator: "\n").utf8)), language: swift, definitions: false)
        #expect(whole.tokens[2].map(\.kind) == [.comment])
        #expect(whole.tokens[4].first?.kind == .keyword)
        #expect(whole.definitions == nil)
        let crlf = await analysis.analysis(of: lines.map { $0 + "\r" }, oid: "crlf", language: swift, definitions: true)
        #expect(crlf.tokens == whole.tokens)
        #expect(crlf.definitions?.map(\.name) == ["f"])
    }
}
