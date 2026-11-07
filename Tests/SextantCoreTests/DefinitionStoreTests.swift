import Foundation
import Testing
@testable import SextantCore

/// Runs the definitions the content analysis keeps against repositories and sources built in
/// the test.
@Suite struct DefinitionStoreTests {
    @Test func aSnapshotWithoutCodeKeepsTheDefinitionsOfOthers() async throws {
        let r = try ScratchRepo("store-prune")
        try r.write("notes.txt", "Words\n")
        try r.commitAll("Docs")
        let docs = Snapshot.commit(try r.git("rev-parse", "HEAD"))
        try r.write("main.swift", "func run() {}\n")
        try r.commitAll("Code")
        let code = Snapshot.commit(try r.git("rev-parse", "HEAD"))

        let index = DefinitionIndex(analysis: ContentAnalysis(cache: nil))
        let parsed = ParseCount()
        #expect(try await index.definitions(in: code, git: r.repo) { _, total in parsed.set(total) }.map(\.name) == ["run"])
        #expect(parsed.value == 1)
        #expect(try await index.definitions(in: docs, git: r.repo).isEmpty)
        parsed.set(0)
        #expect(try await index.definitions(in: code, git: r.repo) { _, total in parsed.set(total) }.map(\.name) == ["run"])
        #expect(parsed.value == 0)
    }

    @Test func aFileChangedAfterGitHashedItIsSavedAsTheVersionRead() async throws {
        let swift = try #require(SyntaxRuntime.shared?.language(forPath: "a.swift"))
        let hashed = Data("func hashed() {}\n".utf8), written = Data("func written() {}\n".utf8)
        let analysis = ContentAnalysis(cache: nil)
        func source(_ named: Data, reading: Data) -> ContentAnalysis.Source {
            ContentAnalysis.Source(key: ContentKey(oid: blobID(of: named), grammar: swift.version), language: swift, read: { reading })
        }

        let raced = source(hashed, reading: written)
        #expect(try await analysis.definitions(of: [raced])[raced.key]?.map(\.name) == ["written"])
        let settled = source(hashed, reading: hashed)
        #expect(try await analysis.definitions(of: [settled])[settled.key]?.map(\.name) == ["hashed"])
        let parsed = ParseCount()
        let rehashed = source(written, reading: written)
        #expect(try await analysis.definitions(of: [rehashed]) { _, total in parsed.set(total) }[rehashed.key]?.map(\.name) == ["written"])
        #expect(parsed.value == 0)
    }

    @Test func aFileThatCouldNotBeReadIsReadAgainNextTime() async throws {
        let swift = try #require(SyntaxRuntime.shared?.language(forPath: "a.swift"))
        let contents = Data("func later() {}\n".utf8)
        let reads = ParseCount()
        let source = ContentAnalysis.Source(key: ContentKey(oid: blobID(of: contents), grammar: swift.version), language: swift) {
            reads.increment() == 1 ? nil : contents
        }
        let analysis = ContentAnalysis(cache: nil)
        #expect(try await analysis.definitions(of: [source])[source.key] == nil)
        #expect(try await analysis.definitions(of: [source])[source.key]?.map(\.name) == ["later"])
        #expect(reads.value == 2)
    }

    @Test func contentsTooLargeOrBinaryAreReadOnce() async throws {
        let swift = try #require(SyntaxRuntime.shared?.language(forPath: "a.swift"))
        let reads = ParseCount()
        let binary = Data("func f() {}\n\0".utf8), large = Data(repeating: 0x20, count: ContentLimits.analysisBytes + 1)
        let sources = [binary, large].map { data in
            ContentAnalysis.Source(key: ContentKey(oid: blobID(of: data), grammar: swift.version), language: swift) {
                reads.increment()
                return data
            }
        }
        let analysis = ContentAnalysis(cache: nil)
        for _ in 0..<2 {
            let found = try await analysis.definitions(of: sources)
            #expect(sources.map { found[$0.key] } == [[], []])
        }
        #expect(reads.value == 2)
    }
}
