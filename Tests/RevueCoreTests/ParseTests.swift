import Foundation
import Testing
@testable import RevueCore

@Test func unquotesGitPaths() {
    #expect(unquoteGitPath("\"tab\\tname\"") == "tab\tname")
    #expect(unquoteGitPath("\"sp\\303\\244ce\"") == "späce")
    #expect(unquoteGitPath("\"quote\\\"d\"") == "quote\"d")
    #expect(unquoteGitPath("plain") == "plain")
}

private func rawPatch(_ raw: [String], _ patch: String) -> Data {
    var d = Data()
    for r in raw { d.append(Data(r.utf8)); d.append(0) }
    d.append(0)
    d.append(Data(patch.utf8))
    return d
}

@Test func parsesRawPatchWithRenameBinaryAndNoNewline() {
    let a = String(repeating: "a", count: 40), b = String(repeating: "b", count: 40)
    let c = String(repeating: "c", count: 40), d = String(repeating: "d", count: 40)
    let data = rawPatch([
        ":100644 100644 \(a) \(b) M", "bin.png",
        ":100644 100755 \(c) \(d) R087", "old name.c", "src/new.c",
    ], """
    diff --git a/bin.png b/bin.png
    index aaaaaaa..bbbbbbb 100644
    Binary files a/bin.png and b/bin.png differ
    diff --git a/old name.c b/src/new.c
    old mode 100644
    new mode 100755
    similarity index 87%
    rename from old name.c
    rename to src/new.c
    --- a/old name.c
    +++ b/src/new.c
    @@ -1,3 +1,3 @@ int main()
     one
    -two
    +TWO
     three
    \\ No newline at end of file

    """)
    let files = parseRawPatchZ(data)
    #expect(files.count == 2)
    #expect(files[0].isBinary)
    #expect(files[0].path == "bin.png")
    let r = files[1]
    #expect(r.change.status == "R")
    #expect(r.change.score == 87)
    #expect(r.change.oldPath == "old name.c")
    #expect(r.path == "src/new.c")
    #expect(r.notes.contains("old mode 100644"))
    #expect(r.hunks.count == 1)
    let h = r.hunks[0]
    #expect(h.section == "int main()")
    #expect(h.lines.map(\.kind) == [.context, .deleted, .added, .context])
    #expect(h.lines.map(\.oldNo) == [1, 2, 0, 3])
    #expect(h.lines.map(\.newNo) == [1, 0, 2, 3])
    #expect(h.lines.last?.noNewline == true)
    #expect(r.additions == 1 && r.deletions == 1)
}

@Test func parsesHunkHeaderWithoutCounts() {
    let h = parseHunkHeader("@@ -5 +7 @@")!
    #expect(h.0 == 5 && h.1 == 1 && h.2 == 7 && h.3 == 1 && h.4 == "")
    let c = parseHunkHeader("@@@ -1,2 -1,2 +1,3 @@@ fn")!
    #expect(c.0 == 1 && c.2 == 1 && c.3 == 3 && c.4 == "fn")
}

@Test func parsesLogWithDecorationsAndRaw() {
    let a = String(repeating: "a", count: 40), z = zeroOid
    let text = "\u{1e}\(a)\u{1f}p1 p2\u{1f}Ada\u{1f}ada@x\u{1f}100\u{1f}HEAD -> main, origin/main, tag: v1\u{1f}Merge it\n\n:000000 100644 \(z) \(a) A\t\"tab\\tname\"\n"
    let commits = parseLog(Data(text.utf8))
    #expect(commits.count == 1)
    #expect(commits[0].parents == ["p1", "p2"])
    #expect(commits[0].isMerge)
    #expect(commits[0].refs == ["main", "origin/main", "v1"])
    #expect(commits[0].changes.first?.path == "tab\tname")
    #expect(commits[0].subject == "Merge it")
}

@Test func untrackedFileBecomesSingleAddedHunk() {
    let d = untrackedFileDiff(path: "n.txt", oid: "x", contents: Data("a\r\nb".utf8))
    #expect(d.hunks.count == 1)
    #expect(d.hunks[0].lines.map(\.text) == ["a", "b"])
    #expect(d.hunks[0].lines.last?.noNewline == true)
    #expect(untrackedFileDiff(path: "b", oid: "x", contents: Data([0, 1, 2])).isBinary)
    #expect(untrackedFileDiff(path: "e", oid: "x", contents: Data()).hunks.isEmpty)
}

/// Builds a hunk from (kind, text) pairs, numbering lines from `oldStart`/`newStart`.
private func hunk(_ oldStart: Int, _ newStart: Int, _ lines: [(LineKind, String)]) -> Hunk {
    var o = oldStart, n = newStart
    var out: [DiffLine] = []
    for (k, t) in lines {
        switch k {
        case .context: out.append(DiffLine(kind: k, oldNo: o, newNo: n, text: t)); o += 1; n += 1
        case .deleted: out.append(DiffLine(kind: k, oldNo: o, newNo: 0, text: t)); o += 1
        case .added: out.append(DiffLine(kind: k, oldNo: 0, newNo: n, text: t)); n += 1
        }
    }
    return Hunk(oldStart: oldStart, oldCount: o - oldStart, newStart: newStart, newCount: n - newStart, section: "", lines: out)
}

@Test func wholeFileFillsUnchangedLinesAroundHunks() {
    let old = (1...12).map { "L\($0)" }
    let hunks = [
        hunk(2, 2, [(.context, "L2"), (.deleted, "L3"), (.context, "L4")]),
        hunk(7, 6, [(.context, "L7"), (.deleted, "L8"), (.added, "a"), (.added, "b"), (.context, "L9")]),
    ]
    let all = wholeFile(hunks, oldLines: old)
    #expect(all.map(\.text) == ["L1", "L2", "L3", "L4", "L5", "L6", "L7", "L8", "a", "b", "L9", "L10", "L11", "L12"])
    #expect(all.filter { $0.kind != .added }.map(\.oldNo) == Array(1...12))
    #expect(all.filter { $0.kind != .deleted }.map(\.newNo) == Array(1...12))
    #expect(all.last?.oldNo == 12 && all.last?.newNo == 12)
}

@Test func wholeFileHandlesPureInsertionsAndNewFiles() {
    let inserted = DiffLine(kind: .added, oldNo: 0, newNo: 4, text: "x")
    let h = Hunk(oldStart: 3, oldCount: 0, newStart: 4, newCount: 2, section: "",
                 lines: [inserted, DiffLine(kind: .added, oldNo: 0, newNo: 5, text: "y")])
    let all = wholeFile([h], oldLines: ["a", "b", "c", "d"])
    #expect(all.map(\.text) == ["a", "b", "c", "x", "y", "d"])
    #expect(all.last?.newNo == 6)
    let added = hunk(0, 1, [(.added, "one"), (.added, "two")])
    #expect(wholeFile([added], oldLines: []).map(\.text) == ["one", "two"])
}

@Test func foldsLongUnchangedRunsButKeepsContext() {
    func lines(_ kinds: String) -> [DiffLine] {
        kinds.map { DiffLine(kind: $0 == "+" ? .added : .context, oldNo: 0, newNo: 0, text: "") }
    }
    let l = lines(String(repeating: ".", count: 10) + "+" + String(repeating: ".", count: 10))
    #expect(foldedRuns(l, context: 3) == [0..<7, 14..<21])
    let short = lines("...+" + String(repeating: ".", count: 8) + "+...")
    #expect(foldedRuns(short, context: 3, minimum: 4) == [])
    #expect(foldedRuns(short, context: 3, minimum: 2) == [7..<9])
    #expect(foldedRuns(lines(String(repeating: ".", count: 50)), context: 3).isEmpty)
}

@Test func wordDiffHighlightsOnlyChangedTokens() {
    let w = wordDiff("self.entries.get(key).copied()", "self.entries.get(key).cloned()")!
    #expect(w.old == [NSRange(location: 22, length: 6)])
    #expect(w.new == [NSRange(location: 22, length: 6)])
    #expect(wordDiff("completely different", "nothing alike here at all 123") == nil)
}

@Test func pairsDeletionRunsWithFollowingAdditions() {
    let l = hunk(1, 1, [(.context, "a"), (.deleted, "b"), (.deleted, "c"), (.added, "B"), (.context, "d"), (.added, "e")]).lines
    let p = pairChangedLines(l)
    #expect(p.count == 1 && p[0] == (1, 3))
}


@Test func grepOutputStripsRevisionAndKeepsTabsAndNULFreeText() {
    let raw = Data("abc123:src/a b.swift\u{0}14\u{0}10\u{0}\tfunc peek() {\r\nabc123:x.go\u{0}2\u{0}1\u{0}peek := 1\n".utf8)
    let m = parseGrepZ(raw, revisionPrefix: "abc123")
    #expect(m == [
        GrepMatch(path: "src/a b.swift", line: 14, column: 10, text: "\tfunc peek() {"),
        GrepMatch(path: "x.go", line: 2, column: 1, text: "peek := 1"),
    ])
    #expect(parseGrepZ(Data("a:b.txt\u{0}1\u{0}1\u{0}x\n".utf8), revisionPrefix: nil).map(\.path) == ["a:b.txt"])
}

@Test func blamePorcelainSharesCommitInfoAcrossLines() {
    let a = String(repeating: "a", count: 40), b = String(repeating: "b", count: 40)
    let raw = """
    \(a) 1 1 2
    author Ada
    author-time 100
    summary First
    filename f
    \tline one
    \(a) 2 2
    \tline two
    \(b) 3 3 1
    author Grace
    author-time 200
    summary Second
    previous \(a) f
    filename f
    \t
    """
    let blame = parseBlamePorcelain(Data(raw.utf8))
    #expect(blame.lines == [a, a, b])
    #expect(blame.commit(forLine: 1)?.summary == "First")
    #expect(blame.commit(forLine: 2)?.author == "Grace")
    #expect(blame.commit(forLine: 2)?.date == Date(timeIntervalSince1970: 200))
    #expect(blame.commit(forLine: 3) == nil)
}
