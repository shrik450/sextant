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
    let skipped = tokens.filter { [.keyword, .comment, .string, .number].contains($0.kind) }.map(\.range)
    let scalars = text.unicodeScalars.map { (s: $0, length: $0.utf16.count) }
    func isIdentifier(_ s: UnicodeScalar) -> Bool { CharacterSet.alphanumerics.contains(s) || s == "_" || s == "$" }
    var out: [NSRange] = []
    var i = 0, offset = 0
    while i < scalars.count {
        guard isIdentifier(scalars[i].s) else { offset += scalars[i].length; i += 1; continue }
        let start = offset, first = scalars[i].s
        while i < scalars.count, isIdentifier(scalars[i].s) { offset += scalars[i].length; i += 1 }
        let r = NSRange(location: start, length: offset - start)
        if !(first.value >= 0x30 && first.value <= 0x39), !skipped.contains(where: { NSIntersectionRange($0, r).length > 0 }) { out.append(r) }
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
    let pieces = ["a", "b_", "$x", "9", "0x1F", " ", "  ", "\t", ".", "(", ")", "é", "日本", "😀", "𝕏", "𝟘", "𠀀", "_", "z9", "=", "\"s\"", "//"]
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

private func line(_ kind: LineKind, _ old: Int, _ new: Int, _ text: String) -> DiffLine {
    DiffLine(kind: kind, oldNo: kind == .added ? 0 : old, newNo: kind == .deleted ? 0 : new, text: text)
}

/// Two functions that each gain the same guard, as hunks a diff with no context would give,
/// and as the whole file.
private let guards = (
    whole: [
        line(.context, 1, 1, "func a() {"),
        line(.added, 0, 2, "    guard ready else { return }"),
        line(.context, 2, 3, "}"),
        line(.context, 3, 4, "func b() {"),
        line(.added, 0, 5, "    guard ready else { return }"),
        line(.context, 4, 6, "}"),
    ],
    hunks: [
        line(.added, 0, 2, "    guard ready else { return }"),
        line(.added, 0, 5, "    guard ready else { return }"),
    ]
)

private func keys(_ lines: [DiffLine], gapsBefore: [Int: Int] = [:]) -> [String] {
    changeKeys(lines, runs: changeRuns(lines, gapsBefore: gapsBefore))
}

@Test func identicalRunsInAFileHaveTheirOwnKeys() {
    let k = keys(guards.whole)
    #expect(k.count == 2 && Set(k).count == 2)
}

@Test func runsEndWhereHunksLeaveLinesOutAndKeepTheirKeysInTheWholeFile() {
    #expect(changeRuns(guards.hunks, gapsBefore: [1: 2]).map(\.lines) == [0..<1, 1..<2])
    #expect(keys(guards.hunks, gapsBefore: [1: 2]) == keys(guards.whole))
}

@Test func aRunKeepsItsKeyWhenTheFileChangesElsewhere() {
    let before = [
        line(.context, 1, 1, "one"),
        line(.deleted, 2, 0, "two"),
        line(.added, 0, 2, "TWO"),
        line(.context, 3, 3, "three"),
        line(.added, 0, 4, "    guard ready else { return }"),
        line(.context, 4, 5, "four"),
    ]
    let after = [
        line(.added, 0, 1, "zero"),
        line(.context, 1, 2, "one"),
        line(.deleted, 2, 0, "two"),
        line(.added, 0, 3, "TWO"),
        line(.context, 3, 4, "three"),
        line(.added, 0, 5, "    guard ready else { return }"),
        line(.context, 4, 6, "four"),
        line(.added, 0, 7, "    guard ready else { return }"),
    ]
    let old = keys(before), new = keys(after)
    #expect(new.count == 4)
    #expect(new[1] == old[0] && new[2] == old[1])
    #expect(!old.contains(new[0]) && !old.contains(new[3]))
}

private func file(_ newOid: String, path: String = "f") -> RawChange {
    RawChange(status: "M", oldMode: "100644", newMode: "100644", oldOid: "base", newOid: newOid, oldPath: path, path: path)
}

@Test func readingOneOfIdenticalRunsLeavesTheOtherUnread() {
    var s = ReadingState()
    let k = keys(guards.whole), f = file("v1")
    s.setRead(k[0], in: f, all: k, to: true)
    #expect(s.isRead(k[0], in: f))
    #expect(!s.isRead(k[1], in: f))
    #expect(!s.isReviewed(f))
}

@Test func readingEveryChangeReviewsTheFile() {
    var s = ReadingState()
    let f = file("v1")
    s.setRead("1", in: f, all: ["1", "2"], to: true)
    #expect(s.isRead("1", in: f))
    #expect(!s.isReviewed(f))
    s.setRead("2", in: f, all: ["1", "2"], to: true)
    #expect(s.isReviewed(f))
}

@Test func readingAChangeOfAFileWithoutChangesDoesNotReviewIt() {
    var s = ReadingState()
    s.setRead("1", in: file("v1"), all: [], to: true)
    #expect(!s.isReviewed(file("v1")))
}

@Test func changesReadStayReadWhenTheFileChangesElsewhere() {
    var s = ReadingState()
    s.setRead("1", in: file("v1"), all: ["1", "2"], to: true)
    #expect(s.isRead("1", in: file("v2")))
    #expect(!s.isRead("2", in: file("v2")))
    #expect(!s.isRead("1", in: file("v1", path: "g")))
}

@Test func reviewingAFileReadsItsChangesForItsNextVersion() {
    var s = ReadingState()
    s.setReviewed([file("v1")], to: true, changes: [file("v1"): ["1", "2"]])
    #expect(s.isReviewed(file("v1")))
    #expect(!s.isReviewed(file("v2")))
    #expect(s.isRead("1", in: file("v2")) && s.isRead("2", in: file("v2")))
    #expect(!s.isRead("3", in: file("v2")))
}

@Test func unreadingAChangeUnreviewsTheFileButKeepsTheOthersRead() {
    var s = ReadingState()
    let f = file("v1")
    s.setReviewed([f], to: true)
    s.setRead("1", in: f, all: ["1", "2"], to: false)
    #expect(!s.isReviewed(f))
    #expect(!s.isRead("1", in: f))
    #expect(s.isRead("2", in: f))
}

@Test func unreviewingAFileUnreadsItsChanges() {
    var s = ReadingState()
    let f = file("v1"), g = file("v1", path: "g")
    s.setRead("1", in: f, all: ["1", "2"], to: true)
    s.setRead("1", in: g, all: ["1", "2"], to: true)
    s.setReviewed([f], to: true)
    #expect(s.isRead("2", in: f))
    s.setReviewed([f], to: false)
    #expect(!s.isRead("1", in: f) && !s.isRead("1", in: file("v2")))
    #expect(s.isRead("1", in: g))
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

@Test func onlyLinesThatReadTheSameSayHowTheyEnd() {
    var lines = [line(.deleted, 1, 0, "a"), line(.deleted, 2, 0, "b"), line(.added, 0, 1, "a"), line(.added, 0, 2, "B"),
                 line(.deleted, 3, 0, "c"), line(.added, 0, 3, "c")]
    lines[0].carriageReturn = true
    lines[1].carriageReturn = true
    lines[4].carriageReturn = true
    lines[5].carriageReturn = true
    #expect(changedLineEndings(lines) == [0: "CRLF", 2: "LF"])
    var cr = line(.deleted, 1, 0, "z")
    cr.carriageReturn = true
    cr.noNewline = true
    #expect(changedLineEndings([cr, line(.added, 0, 1, "z")]) == [0: "CR, no newline at end of file", 1: "LF"])
}

@Test func aRunsKeyFollowsItsLinesAndTheirEndings() {
    let crlf = [line(.deleted, 1, 0, "two"), line(.added, 0, 1, "two")]
    var lf = crlf
    lf[0].carriageReturn = true
    #expect(keys(crlf) != keys(lf))
    #expect(keys([line(.added, 0, 1, "x")]) != keys([line(.deleted, 1, 0, "x")]))
}


@Test func aReferenceNamesTheSideTheSelectedLinesAreOn() {
    let lines = [line(.context, 1, 1, "a"), line(.deleted, 2, 0, "b"), line(.deleted, 3, 0, "c"), line(.added, 0, 2, "B"), line(.context, 4, 3, "d")]
    #expect(referencedLines([0, 1, 2], in: lines, old: nil).map { [$0.lines.lowerBound, $0.lines.upperBound] } == [1, 3])
    #expect(referencedLines([0, 1, 2], in: lines, old: nil)?.old == true)
    #expect(referencedLines([0, 1, 2], in: lines, old: nil)?.code == ["a", "b", "c"])
    #expect(referencedLines([1, 2, 3], in: lines, old: nil)?.code == ["B"])
    #expect(referencedLines([3, 4], in: lines, old: nil)?.old == false)
    #expect(referencedLines([4], in: lines, old: true).map { [$0.lines.lowerBound, $0.lines.upperBound] } == [4, 4])
    #expect(referencedLines([4], in: lines, old: nil).map { [$0.lines.lowerBound, $0.lines.upperBound] } == [3, 3])
    #expect(referencedLines([3], in: lines, old: true) == nil)
    #expect(referencedLines([9], in: lines, old: nil) == nil)
}

@Test func lettersBeyondTheBasicPlaneArePartOfNames() {
    #expect(identifiers(in: "let 𝕏 = x𝕏y + 😀", tokens: []) == [NSRange(location: 0, length: 3), NSRange(location: 4, length: 2), NSRange(location: 9, length: 4)])
    #expect(wholeWordMatches(of: "foo", in: "𝕏foo foo𝕏 foo").map(\.location) == [12])
    let text = "a 𝕏b c" as NSString
    #expect(identifier(at: 2, in: text) == NSRange(location: 2, length: 3))
    #expect(identifier(at: 3, in: text) == NSRange(location: 2, length: 3))
    let across = String(repeating: " ", count: 4095) + "𝕏yz"
    #expect(identifiers(in: across, tokens: []) == [NSRange(location: 4095, length: 4)])
}
