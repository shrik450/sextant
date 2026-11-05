import Foundation
import Testing
@testable import SextantCore

private func fields(_ records: [[String]]) -> Data {
    var d = Data()
    for r in records {
        for f in r { d.append(Data(f.utf8)); d.append(0) }
        d.append(0)
    }
    return d
}

@Test func parsesWorktreesSkippingBareAndPrunable() {
    let a = String(repeating: "a", count: 40), b = String(repeating: "b", count: 40)
    let list = parseWorktreeList(fields([
        ["worktree /repo", "HEAD \(a)", "branch refs/heads/main"],
        ["worktree /repo.git", "bare"],
        ["worktree /wt/agent", "HEAD \(b)", "detached"],
        ["worktree /wt/gone", "HEAD \(b)", "branch refs/heads/old", "prunable gitdir file points to non-existent location"],
        ["worktree /wt/new", "HEAD \(zeroOid)", "branch refs/heads/fresh"],
    ]))
    #expect(list.map(\.root.path) == ["/repo", "/wt/agent", "/wt/new"])
    #expect(list.map(\.branch) == ["main", nil, "fresh"])
    #expect(list.map(\.head) == [a, b, nil])
    #expect(list[1].name == "agent")
}

@Test func parsesBranchesWithDistanceFromBase() {
    let line = { (ref: String, counts: String, subject: String) in
        [ref, String(repeating: "c", count: 40), "1767225600", counts, subject].joined(separator: "\0")
    }
    let data = Data([
        line("refs/heads/feature/x", "2 5", "Add x"),
        line("refs/remotes/origin/HEAD", "", "Tip"),
        line("refs/remotes/origin/feature/y", "", "Subject with\0nul"),
        line("refs/tags/v1", "0 0", "Tagged"),
    ].joined(separator: "\n").utf8)
    let branches = parseBranches(data)
    #expect(branches.map(\.name) == ["feature/x", "origin/feature/y"])
    #expect(branches.map(\.isRemote) == [false, true])
    #expect(branches[0].ahead == 2 && branches[0].behind == 5)
    #expect(branches[1].ahead == nil && branches[1].behind == nil)
    #expect(branches[1].subject == "Subject with\0nul")
    #expect(branches[0].date == Date(timeIntervalSince1970: 1767225600))
}

@Test func branchFormatAsksForDistanceOnlyWithABase() {
    #expect(branchFormat(base: "origin/main").contains("%(ahead-behind:origin/main)"))
    #expect(!branchFormat(base: nil).contains("ahead-behind"))
}

@Test func parsesPullRequests() throws {
    let json = """
    [{"number": 387, "title": "Evaluate roc 7", "headRefName": "su/roc-7-eval",
      "headRefOid": "0123456789abcdef0123456789abcdef01234567", "baseRefName": "main", "isDraft": true,
      "author": {"login": "su", "is_bot": false}, "updatedAt": "2026-10-30T12:00:00Z"}]
    """
    let prs = try parsePullRequests(Data(json.utf8))
    #expect(prs.count == 1)
    #expect(prs[0].number == 387 && prs[0].headRefName == "su/roc-7-eval" && prs[0].isDraft)
    #expect(prs[0].author.login == "su")
    #expect(prs[0].updatedAt == Date(timeIntervalSince1970: 1793361600))
}

@Test func parsesRevisionSpecs() {
    #expect(parseRevisionSpec("  ") == nil)
    #expect(parseRevisionSpec("WIP") == .uncommitted)
    #expect(parseRevisionSpec("--cached") == .staged)
    #expect(parseRevisionSpec("unstaged") == .unstaged)
    #expect(parseRevisionSpec("#387") == .pullRequest(387))
    #expect(parseRevisionSpec("#0") == .revision("#0"))
    #expect(parseRevisionSpec("main...feature") == .comparison(from: "main", to: "feature", sinceAncestor: true))
    #expect(parseRevisionSpec("main..") == .comparison(from: "main", to: "HEAD", sinceAncestor: false))
    #expect(parseRevisionSpec("..feature") == .comparison(from: "HEAD", to: "feature", sinceAncestor: false))
    #expect(parseRevisionSpec(" HEAD~3 ") == .revision("HEAD~3"))
}

private func commit(_ oid: String, parent: String?) -> Commit {
    Commit(oid: oid, parents: parent.map { [$0] } ?? [], author: "", email: "", date: Date(), subject: "", refs: [], changes: [])
}

@Test func scopesNarrowTheReview() {
    let commits = [commit("c3", parent: "c2"), commit("c2", parent: "c1"), commit("c1", parent: nil)]
    let all = Target.range(base: "base", head: "c3")
    #expect(scoped(.everything, everything: all, commits: commits) == all)
    #expect(scoped(.uncommitted, everything: all, commits: commits) == .worktree(since: nil))
    #expect(scoped(.staged, everything: all, commits: commits) == .staged)
    #expect(scoped(.commits(newest: "c2", oldest: "c2"), everything: all, commits: commits) == .commit("c2"))
    #expect(scoped(.commits(newest: "c3", oldest: "c2"), everything: all, commits: commits) == .range(base: "c1", head: "c3"))
    #expect(scoped(.commits(newest: "c2", oldest: "c1"), everything: all, commits: commits) == .range(base: emptyTreeOid, head: "c2"))
}

private func outline(_ nodes: [FileNode], depth: Int = 0) -> [String] {
    nodes.flatMap { n -> [String] in
        let pad = String(repeating: "  ", count: depth)
        switch n.kind {
        case .unchanged(let k): return ["\(pad)⋯ \(k) [\(n.path)]"]
        case .file: return ["\(pad)\(n.name)\(n.changed > 0 ? " *" : "")"]
        case .folder: return ["\(pad)\(n.name)/ \(n.reviewed)/\(n.changed)"] + outline(n.children, depth: depth + 1)
        }
    }
}

private let treePaths = [
    "README.md", "docs/guide.md", "src/a.swift", "src/b.swift", "src/deep/x/y.swift", "src/deep/z.txt",
    "crates/core/src/lib.rs", "crates/core/Cargo.toml", "crates/cli/main.rs",
]

@Test func foldsUnchangedFilesAndMergesFolderChains() {
    let tree = fileTree(paths: treePaths, changed: ["src/a.swift", "src/deep/x/y.swift", "crates/core/src/lib.rs"],
                        reviewed: ["src/a.swift"], showUnchanged: false, revealed: [])
    #expect(outline(tree) == [
        "crates/core/src/ 0/1",
        "  lib.rs *",
        "src/ 1/2",
        "  deep/x/ 0/1",
        "    y.swift *",
        "  a.swift *",
        "  ⋯ 1 [src]",
        "⋯ 2 []",
    ])
}

@Test func revealsAFoldersUnchangedItemsInPlace() {
    let tree = fileTree(paths: treePaths, changed: ["src/a.swift", "src/deep/x/y.swift"],
                        reviewed: [], showUnchanged: false, revealed: ["src"])
    #expect(outline(tree) == [
        "src/ 0/2",
        "  deep/x/ 0/1",
        "    y.swift *",
        "  a.swift *",
        "  b.swift",
        "⋯ 3 []",
    ])
}

@Test func showingEverythingMergesOnlyChildFolders() {
    let tree = fileTree(paths: ["a/b/c/one.txt", "a/b/c/two.txt", "top.txt"], changed: ["deleted/gone.txt"],
                        reviewed: [], showUnchanged: true, revealed: [])
    #expect(outline(tree) == [
        "a/b/c/ 0/0",
        "  one.txt",
        "  two.txt",
        "deleted/ 0/1",
        "  gone.txt *",
        "top.txt",
    ])
}

@Test func findsChangeRuns() {
    let lines = [
        DiffLine(kind: .context, oldNo: 1, newNo: 1, text: "a"),
        DiffLine(kind: .deleted, oldNo: 2, newNo: 0, text: "b"),
        DiffLine(kind: .added, oldNo: 0, newNo: 2, text: "B"),
        DiffLine(kind: .added, oldNo: 0, newNo: 3, text: "B2"),
        DiffLine(kind: .context, oldNo: 3, newNo: 4, text: "c"),
        DiffLine(kind: .deleted, oldNo: 4, newNo: 0, text: "d"),
        DiffLine(kind: .context, oldNo: 5, newNo: 5, text: "e"),
    ]
    #expect(changeRuns(lines) == [
        ChangeRun(lines: 1..<4, additions: 2, deletions: 1, newLine: 1),
        ChangeRun(lines: 5..<6, additions: 0, deletions: 1, newLine: 4),
    ])
    #expect(changeRuns([DiffLine(kind: .deleted, oldNo: 1, newNo: 0, text: "x")]) == [ChangeRun(lines: 0..<1, additions: 0, deletions: 1, newLine: 0)])
}

private func definition(_ name: String, _ kind: String, _ lines: ClosedRange<Int>) -> Symbol {
    Symbol(name: name, kind: kind, isDefinition: true, range: NSRange(), nameRange: NSRange(), nameLine: lines.lowerBound, lines: lines)
}

private func describe(_ items: [OutlineItem], depth: Int = 0) -> [String] {
    items.flatMap { i in ["\(String(repeating: "  ", count: depth))\(i.name) \(i.change) @\(i.line)"] + describe(i.children, depth: depth + 1) }
}

@Test func outlinesMarkWhatTheChangeTouched() {
    let lines = [
        DiffLine(kind: .context, oldNo: 1, newNo: 1, text: "struct A {"),
        DiffLine(kind: .context, oldNo: 2, newNo: 2, text: "  func keep() {}"),
        DiffLine(kind: .deleted, oldNo: 3, newNo: 0, text: "  func gone() {}"),
        DiffLine(kind: .added, oldNo: 0, newNo: 3, text: "  func fresh() {}"),
        DiffLine(kind: .context, oldNo: 4, newNo: 4, text: "  func edit() {"),
        DiffLine(kind: .deleted, oldNo: 5, newNo: 0, text: "    old"),
        DiffLine(kind: .added, oldNo: 0, newNo: 5, text: "    new"),
        DiffLine(kind: .context, oldNo: 6, newNo: 6, text: "  }"),
        DiffLine(kind: .context, oldNo: 7, newNo: 7, text: "}"),
        DiffLine(kind: .deleted, oldNo: 8, newNo: 0, text: "func tail() {}"),
    ]
    let new = [definition("A", "class", 0...6), definition("keep", "method", 1...1), definition("fresh", "method", 2...2), definition("edit", "method", 3...5)]
    let old = [definition("A", "class", 0...6), definition("keep", "method", 1...1), definition("gone", "method", 2...2),
               definition("edit", "method", 3...5), definition("tail", "function", 7...7)]
    let items = outline(lines: lines, new: new, old: old)
    #expect(describe(items) == [
        "A modified @0",
        "  keep none @1",
        "  fresh added @2",
        "  gone deleted @2",
        "  edit modified @3",
        "tail deleted @7",
    ])
    #expect(items[0].children[0].isTouched == false && items[0].isTouched)
    #expect(changedDefinitions(in: items, lines: lines).map(\.name) == ["fresh", "gone", "edit", "tail"])
}

@Test func aDefinitionWithChangedLinesOfItsOwnIsAChangedDefinition() {
    let lines = [
        DiffLine(kind: .context, oldNo: 1, newNo: 1, text: "struct B {"),
        DiffLine(kind: .added, oldNo: 0, newNo: 2, text: "  // note"),
        DiffLine(kind: .context, oldNo: 2, newNo: 3, text: "  func f() {}"),
        DiffLine(kind: .context, oldNo: 3, newNo: 4, text: "}"),
    ]
    let items = outline(lines: lines, new: [definition("B", "class", 0...3), definition("f", "method", 2...2)],
                        old: [definition("B", "class", 0...2), definition("f", "method", 1...1)])
    #expect(describe(items) == ["B modified @0", "  f none @2"])
    #expect(changedDefinitions(in: items, lines: lines).map(\.name) == ["B"])
}

@Test func foldsEverythingWhenNothingChanged() {
    let tree = fileTree(paths: treePaths, changed: [], reviewed: [], showUnchanged: false, revealed: [])
    #expect(outline(tree) == ["⋯ 4 []"])
}
