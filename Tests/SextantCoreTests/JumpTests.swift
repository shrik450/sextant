import Foundation
import Testing
@testable import SextantCore

@Test func fuzzyRanksNamesBeforePathsBeforeScatteredLetters() {
    let paths = ["src/design/review.rs", "src/review.rs", "docs/reviewing.md", "src/reader/view.rs", "review/notes.md"]
    #expect(rankFuzzy("review.rs", paths).prefix(2) == ["src/review.rs", "src/design/review.rs"])
    #expect(rankFuzzy("review", paths).prefix(3) == ["src/review.rs", "docs/reviewing.md", "src/design/review.rs"])
    #expect(rankFuzzy("srv", paths).first == "src/reader/view.rs")
    #expect(rankFuzzy("zzz", paths).isEmpty)
}

@Test func fuzzyIgnoresCaseAndFavoursWordStarts() {
    #expect(fuzzyScore("Review", candidate: "a/review.rs", name: "review") == fuzzyScore("review", candidate: "a/review.rs", name: "review"))
    let camel = fuzzyScore("gcf", candidate: "GetCumulativeFeedback", name: "GetCumulativeFeedback")!
    let scattered = fuzzyScore("gcf", candidate: "aggressiveCoffee", name: "aggressiveCoffee")!
    #expect(camel > scattered)
}

@Test func jumpQueriesChooseWhatToSearchByTheirFirstCharacter() {
    #expect(parseJumpQuery("  design.rs ") == .anything("design.rs"))
    #expect(parseJumpQuery("> mark all") == .commands("mark all"))
    #expect(parseJumpQuery(":120") == .line(120))
    #expect(parseJumpQuery(":") == .line(nil))
    #expect(parseJumpQuery("@greet") == .fileDefinitions("greet"))
    #expect(parseJumpQuery("#Cache") == .definitions("Cache"))
    #expect(parseJumpQuery("") == .anything(""))
}

@Test func jumpRanksFilesAndDefinitionsTogetherWithChangesFirst() {
    let defs = [LocatedDefinition(name: "review", kind: "function", path: "src/a.rs", line: 3, inOutline: true),
                LocatedDefinition(name: "reviewer", kind: "struct", path: "src/b.rs", line: 9, inOutline: true)]
    let ranked = rankJump("review", files: ["old/review", "src/review"], changed: ["src/review"], definitions: defs, limit: 10)
    #expect(ranked.first == .file("src/review"))
    #expect(ranked.prefix(3).contains(.definition(defs[0])))
    #expect(ranked.last == .definition(defs[1]))
    #expect(rankJump("review", files: ["src/review"], changed: [], definitions: defs, limit: 1).count == 1)
}

@Test func definitionsKeepLocalsOutOfTheOutline() {
    func symbol(_ name: String, _ kind: String, at start: Int, length: Int, line: Int, isDefinition: Bool = true) -> Symbol {
        Symbol(name: name, kind: kind, isDefinition: isDefinition, range: NSRange(location: start, length: length),
               nameRange: NSRange(location: start, length: name.count), nameLine: line, lines: line...line)
    }
    let found = indexedDefinitions([
        symbol("Parser", "class", at: 0, length: 100, line: 0),
        symbol("next", "method", at: 10, length: 40, line: 1),
        symbol("first", "constant", at: 20, length: 5, line: 2),
        symbol("print", "call", at: 30, length: 5, line: 3, isDefinition: false),
        symbol("limit", "constant", at: 60, length: 5, line: 5),
    ])
    #expect(found == [
        Definition(name: "Parser", kind: "class", line: 1, inOutline: true),
        Definition(name: "next", kind: "method", line: 2, inOutline: true),
        Definition(name: "first", kind: "constant", line: 3, inOutline: false),
        Definition(name: "limit", kind: "constant", line: 6, inOutline: true),
    ])
}

@Test func definitionsSaveCompactlyAndReadBack() throws {
    let defs = [Definition(name: "parse", kind: "function", line: 12, inOutline: true),
                Definition(name: "x", kind: "constant", line: 13, inOutline: false)]
    let data = try JSONEncoder().encode(defs)
    #expect(String(decoding: data, as: UTF8.self) == #"[["parse","function",12,true],["x","constant",13,false]]"#)
    #expect(try JSONDecoder().decode([Definition].self, from: data) == defs)
}

@Test func blobIDMatchesGit() {
    #expect(blobID(of: Data("hello\n".utf8)) == "ce013625030ba8dba906f756967f9e9ca394464a")
    #expect(blobID(of: Data()) == "e69de29bb2d1d6434b8b29ae775ad8c2e48c5391")
}

@Test func listingsKeepRegularFilesOnly() {
    let tree = Data(("100644 blob aaaa\tsrc/a.swift\u{0}100755 blob bbbb\tbin/run\u{0}120000 blob cccc\tlink.swift\u{0}"
        + "160000 commit dddd\tvendor/lib\u{0}040000 tree eeee\tsrc\u{0}").utf8)
    #expect(parseTree(tree).map(\.path) == ["src/a.swift", "bin/run"])
    let staged = Data(("100644 aaaa 0\tsrc/a.swift\u{0}120000 cccc 0\tlink.swift\u{0}160000 dddd 0\tvendor/lib\u{0}"
        + "100644 ffff 2\tconflict.swift\u{0}").utf8)
    #expect(parseStaged(staged).map(\.oid) == ["aaaa"])
}

@Test func placesTakeTheirLinesFromTheSearchAndAppearOnce() {
    let files: [(path: String, definitions: [Definition])] = [
        ("a.swift", [Definition(name: "run", kind: "function", line: 3, inOutline: true),
                     Definition(name: "run", kind: "method", line: 3, inOutline: true),
                     Definition(name: "stop", kind: "function", line: 9, inOutline: true)]),
        ("b.swift", [Definition(name: "run", kind: "constant", line: 7, inOutline: false)]),
    ]
    let matches = [GrepMatch(path: "a.swift", line: 3, column: 6, text: "func run() {"),
                   GrepMatch(path: "b.swift", line: 2, column: 1, text: "run()")]
    #expect(places(of: "run", in: files, matches: matches) == [
        GrepMatch(path: "a.swift", line: 3, column: 1, text: "func run() {"),
        GrepMatch(path: "b.swift", line: 7, column: 1, text: "run"),
    ])
}
