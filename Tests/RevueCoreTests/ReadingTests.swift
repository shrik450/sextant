import Foundation
import Testing
@testable import RevueCore

private func token(_ location: Int, _ length: Int, _ kind: TokenKind) -> Token {
    Token(range: NSRange(location: location, length: length), kind: kind)
}

@Test func identifiersSkipKeywordsLiteralsAndComments() {
    let line = "const EVAL_FIXTURE: &str = \"x/y\"; // read it 42"
    let tokens = [token(0, 5, .keyword), token(27, 5, .string), token(34, 15, .comment)]
    let names = identifiers(in: line, tokens: tokens).map { (line as NSString).substring(with: $0) }
    #expect(names == ["EVAL_FIXTURE", "str"])
}

@Test func identifiersSkipNumbersWithoutTokens() {
    let names = identifiers(in: "x1 = 0x10 + y", tokens: []).map { ("x1 = 0x10 + y" as NSString).substring(with: $0) }
    #expect(names == ["x1", "y"])
}

@Test func landsOnTheChangedNameThenTheFirstNameThenTheText() {
    let line = "    let payload = read(&fs::path)"
    let tokens = [token(4, 3, .keyword)]
    #expect(landingColumn(in: line, tokens: tokens, changed: [NSRange(location: 23, length: 4)]) == 24)
    #expect(landingColumn(in: line, tokens: tokens, changed: []) == 8)
    #expect(landingColumn(in: "    });", tokens: [], changed: []) == 4)
    #expect(landingColumn(in: "   ", tokens: [], changed: []) == 0)
}

@Test func findsWholeWordsOnly() {
    let text = "fixture eval_fixture fixture_x fixture"
    #expect(wholeWordMatches(of: "fixture", in: text).map(\.location) == [0, 31])
}

@Test func jumpTargetsUseSmartCase() {
    let lines = ["Eval eval", "medieval"]
    #expect(jumpTargets(for: "ev", in: lines) == [JumpTarget(line: 0, column: 0), JumpTarget(line: 0, column: 5), JumpTarget(line: 1, column: 4)])
    #expect(jumpTargets(for: "Ev", in: lines) == [JumpTarget(line: 0, column: 0)])
}

@Test func jumpLabelsUseOneKeyUntilThereAreTooManyTargets() {
    #expect(jumpLabels(3) == ["a", "s", "d"])
    let many = jumpLabels(30)
    #expect(many.count == 30)
    #expect(many.allSatisfy { $0.count == 2 })
    #expect(Set(many).count == 30)
}

@Test func changeKeysFollowContentAndFile() {
    let a = [DiffLine(kind: .added, oldNo: 0, newNo: 3, text: "use std::fs;")]
    let b = [DiffLine(kind: .deleted, oldNo: 3, newNo: 0, text: "use std::fs;")]
    #expect(changeKey(file: "f1", lines: a) == changeKey(file: "f1", lines: a))
    #expect(changeKey(file: "f1", lines: a) != changeKey(file: "f1", lines: b))
    #expect(changeKey(file: "f1", lines: a) != changeKey(file: "f2", lines: a))
    #expect(changeKey(file: "f1", lines: a).hasPrefix("f1#"))
}

@Test func readingEveryChangeReviewsTheFile() {
    var s = ReadingState()
    let keys = ["f#1", "f#2"]
    s.setRead("f#1", in: "f", all: keys, to: true)
    #expect(s.isRead("f#1", in: "f"))
    #expect(!s.isReviewed("f"))
    s.setRead("f#2", in: "f", all: keys, to: true)
    #expect(s.isReviewed("f"))
    #expect(s.read.isEmpty)
}

@Test func unreadingAChangeUnreviewsTheFileButKeepsTheOthersRead() {
    var s = ReadingState()
    s.setReviewed(["f"], to: true)
    s.setRead("f#1", in: "f", all: ["f#1", "f#2"], to: false)
    #expect(!s.isReviewed("f"))
    #expect(!s.isRead("f#1", in: "f"))
    #expect(s.isRead("f#2", in: "f"))
}

@Test func reviewingAFileReadsItsChangesAndUnreviewingUnreadsThem() {
    var s = ReadingState()
    s.setRead("f#1", in: "f", all: ["f#1", "f#2"], to: true)
    s.setRead("g#1", in: "g", all: ["g#1", "g#2"], to: true)
    s.setReviewed(["f"], to: true)
    #expect(s.isRead("f#2", in: "f"))
    s.setReviewed(["f"], to: false)
    #expect(!s.isRead("f#1", in: "f"))
    #expect(s.isRead("g#1", in: "g"))
}

@Test func subjectKeysNameTheSubject() {
    #expect(Subject.pullRequest(387).key == "pr:387")
    #expect(Subject.worktree(URL(fileURLWithPath: "/a/b/../c")).key == "worktree:/a/c")
    #expect(Subject.comparison(from: "a", to: "b", sinceAncestor: true).key == "compare:a...b")
}

@Test func changesStartWhereChangedRowsFollowUnchangedOnes() {
    let changed = ".++..+...+++.".map { $0 == "+" }
    #expect(changeStarts(changed) == [1, 5, 9])
    #expect(changeStarts([true, true]) == [0])
    #expect(changeStarts([Bool]()).isEmpty)
}

@Test func countsWhichChangeARowIsIn() {
    let starts = [1, 5, 9]
    #expect(changeOrdinal(atRow: 0, starts: starts) == 0)
    #expect(changeOrdinal(atRow: 1, starts: starts) == 1)
    #expect(changeOrdinal(atRow: 4, starts: starts) == 1)
    #expect(changeOrdinal(atRow: 5, starts: starts) == 2)
    #expect(changeOrdinal(atRow: 100, starts: starts) == 3)
    #expect(changeOrdinal(atRow: 3, starts: []) == 0)
}
