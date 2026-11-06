import Foundation
import Testing
@testable import SextantCore

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

private func landing(_ line: String, tokens: [Token], changed: [NSRange]) -> Int {
    landingColumn(in: line as NSString, range: NSRange(location: 0, length: (line as NSString).length), tokens: tokens, changed: changed)
}

@Test func landsOnTheChangedNameThenTheFirstNameThenTheText() {
    let line = "    let payload = read(&fs::path)"
    let tokens = [token(4, 3, .keyword)]
    #expect(landing(line, tokens: tokens, changed: [NSRange(location: 23, length: 4)]) == 24)
    #expect(landing(line, tokens: tokens, changed: []) == 8)
    #expect(landing("    });", tokens: [], changed: []) == 4)
    #expect(landing("   ", tokens: [], changed: []) == 0)
}

@Test func identifierUnitsAreTheAlphanumericsUnderscoreAndDollar() {
    for u in 0...UInt16.max {
        let expected = UnicodeScalar(u).map { CharacterSet.alphanumerics.contains($0) || $0 == "_" || $0 == "$" } ?? false
        #expect(isIdentifierUnit(u) == expected, "unit \(u)")
    }
}

private func quadraticIdentifiers(in text: String, tokens: [Token]) -> [NSRange] {
    let s = text as NSString
    let skipped = tokens.filter { [.keyword, .comment, .string, .number].contains($0.kind) }.map(\.range)
    var out: [NSRange] = []
    var i = 0
    while i < s.length {
        guard isIdentifierUnit(s.character(at: i)) else { i += 1; continue }
        let start = i
        while i < s.length, isIdentifierUnit(s.character(at: i)) { i += 1 }
        let r = NSRange(location: start, length: i - start)
        let u = s.character(at: start)
        if !(u >= 0x30 && u <= 0x39), !skipped.contains(where: { NSIntersectionRange($0, r).length > 0 }) { out.append(r) }
    }
    return out
}

private func quadraticLandingColumn(in text: String, tokens: [Token], changed: [NSRange]) -> Int {
    let names = quadraticIdentifiers(in: text, tokens: tokens)
    if let touched = names.first(where: { n in changed.contains { NSIntersectionRange($0, n).length > 0 } }) { return touched.location }
    if let first = names.first { return first.location }
    let s = text as NSString
    var i = 0
    while i < s.length, s.character(at: i) == 0x20 || s.character(at: i) == 0x09 { i += 1 }
    return i == s.length ? 0 : i
}

private struct SeededRandom: RandomNumberGenerator {
    var state: UInt64
    mutating func next() -> UInt64 {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return state ^ (state >> 29)
    }
}

private func randomRanges(in length: Int, count: Int, using g: inout SeededRandom) -> [NSRange] {
    (0..<count).map { _ in
        let start = Int.random(in: 0...length, using: &g)
        return NSRange(location: start, length: Int.random(in: 0...max(0, min(12, length - start)), using: &g))
    }
}

@Test func identifiersAndLandingMatchCheckingEveryTokenForEveryName() {
    var g = SeededRandom(state: 42)
    let pieces = ["a", "b_", "$x", "9", "0x1F", " ", "  ", "\t", ".", "(", ")", "é", "日本", "😀", "_", "z9", "=", "\"s\"", "//"]
    let kinds: [TokenKind] = [.keyword, .string, .comment, .number, .type, .function, .variable]
    for _ in 0..<3000 {
        let text = (0..<Int.random(in: 0...30, using: &g)).map { _ in pieces.randomElement(using: &g)! }.joined()
        let length = (text as NSString).length
        var tokens = randomRanges(in: length, count: Int.random(in: 0...8, using: &g), using: &g)
            .map { Token(range: $0, kind: kinds.randomElement(using: &g)!) }
        if Bool.random(using: &g) { tokens.sort { $0.range.location < $1.range.location } }
        let changed = randomRanges(in: length, count: Int.random(in: 0...3, using: &g), using: &g)
        #expect(identifiers(in: text, tokens: tokens) == quadraticIdentifiers(in: text, tokens: tokens), "\(text) \(tokens)")
        #expect(landing(text, tokens: tokens, changed: changed) == quadraticLandingColumn(in: text, tokens: tokens, changed: changed),
                "\(text) \(tokens) \(changed)")
    }
}

@Test func identifiersCrossTheChunksTheLineIsReadIn() {
    let line = String(repeating: "ab ", count: 1365) + "name_across_the_boundary + tail"
    let tokens = [token(4094, 5, .keyword)]
    #expect(identifiers(in: line, tokens: tokens) == quadraticIdentifiers(in: line, tokens: tokens))
    #expect(identifiers(in: line, tokens: []).count == 1365 + 2)
}

@Test func landingReadsALineInsideALargerText() {
    let text = "first line\n    let payload = read(x)\nlast" as NSString
    let range = text.range(of: "    let payload = read(x)")
    #expect(landingColumn(in: text, range: range, tokens: [token(4, 3, .keyword)], changed: [NSRange(location: 18, length: 4)]) == 18)
    #expect(landingColumn(in: text, range: range, tokens: [token(4, 3, .keyword)], changed: []) == 8)
}

@Test func findsTheIdentifierAtOrJustBeforeAnOffset() {
    let text = "let a_b$ = f(é1)" as NSString
    #expect(identifier(at: 5, in: text) == NSRange(location: 4, length: 4))
    #expect(identifier(at: 8, in: text) == NSRange(location: 4, length: 4))
    #expect(identifier(at: 9, in: text) == nil)
    #expect(identifier(at: 13, in: text) == NSRange(location: 13, length: 2))
    #expect(identifier(at: 99, in: text) == NSRange(location: 13, length: 2))
    #expect(identifier(at: 0, in: "" as NSString) == nil)
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
    #expect(Subject.worktree(CanonicalPath(path: "/a/b/../c")).key == "worktree:/a/c")
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
