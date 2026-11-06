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
}
