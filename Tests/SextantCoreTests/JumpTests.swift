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
    let defs = [LocatedDefinition(name: "review", kind: "function", path: "src/a.rs", line: 3),
                LocatedDefinition(name: "reviewer", kind: "struct", path: "src/b.rs", line: 9)]
    let ranked = rankJump("review", files: ["old/review", "src/review"], changed: ["src/review"], definitions: defs, limit: 10)
    #expect(ranked.first == .file("src/review"))
    #expect(ranked.prefix(3).contains(.definition(defs[0])))
    #expect(ranked.last == .definition(defs[1]))
    #expect(rankJump("review", files: ["src/review"], changed: [], definitions: defs, limit: 1).count == 1)
}
