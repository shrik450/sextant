import Foundation
import Testing
@testable import SextantCore

@Suite struct AdmissionTests {
    @Test func measuringCountsLinesAsSplittingThemDoes() {
        for text in ["", "a", "a\n", "a\nb", "a\r\nbb\r\n", "\n\n", "one\ntwo\nthree\n"] {
            let data = Data(text.utf8)
            let a = Admission(measuring: data)
            #expect(a.lines == splitLines(data).count, "\(text.debugDescription)")
            #expect(a.longestLine == (splitLines(data).map(\.utf16.count).max() ?? 0), "\(text.debugDescription)")
            #expect(a.bytes == Admission(measuringLines: splitLines(data)).bytes + text.utf8.filter { $0 == 0x0D }.count, "\(text.debugDescription)")
        }
    }

    @Test func aLongLineIsMeasuredInUTF16Units() {
        let width = ContentLimits.analysisLineWidth
        let ascii = Data(String(repeating: "x", count: width + 1).utf8)
        #expect(Admission(measuring: ascii).verdict == .plain)
        let threeByte = Data(String(repeating: "語", count: width).utf8)
        #expect(Admission(measuring: threeByte).longestLine == width)
        #expect(Admission(measuring: threeByte).verdict == .analyzed)
        let astral = Data(String(repeating: "𝕏", count: width / 2 + 1).utf8)
        #expect(Admission(measuring: astral).longestLine == width + 2)
        #expect(Admission(measuring: astral).verdict == .plain)
    }

    @Test func verdictsFollowTheLimits() {
        #expect(Admission(bytes: ContentLimits.analysisBytes, lines: 10, longestLine: 10).verdict == .analyzed)
        #expect(Admission(bytes: ContentLimits.analysisBytes + 1, lines: 10, longestLine: 10).verdict == .plain)
        #expect(Admission(bytes: 10, lines: 1, longestLine: ContentLimits.analysisLineWidth + 1).verdict == .plain)
        #expect(Admission(bytes: ContentLimits.wholeBytes, lines: 10, longestLine: 10).verdict == .plain)
        #expect(Admission(bytes: ContentLimits.wholeBytes + 1, lines: 10, longestLine: 10).verdict == .preview)
        #expect(Admission(bytes: 10, lines: ContentLimits.wholeLines + 1, longestLine: 1).verdict == .preview)
        #expect(Admission(measuring: Data("a\0b".utf8)).verdict == .binary)
        #expect(Admission(bytes: 10, lines: 1, longestLine: 1).reason == nil)
        #expect(Admission(bytes: 10, lines: 1, longestLine: ContentLimits.analysisLineWidth + 1).reason == "a line is longer than 20,000 characters")
    }

    @Test func linesAreCutAtTheLineWidthAndSayHowMuchIsLeft() {
        let width = ContentLimits.lineWidth
        let long = String(repeating: "ab", count: width) + "\nshort\n"
        let admitted = AdmittedLines(Data(long.utf8))
        #expect(admitted.lines.map(\.utf16.count) == [width, 5])
        #expect(admitted.cut == [0: width])
        let wide = String(repeating: "é", count: width + 7)
        let cut = AdmittedLines(Data(wide.utf8))
        #expect(cut.lines == [String(repeating: "é", count: width)])
        #expect(cut.cut == [0: 7])
    }

    @Test func aCutNeverSplitsASurrogatePair() {
        let text = String(repeating: "a", count: ContentLimits.lineWidth - 1) + "𝕏𝕏"
        let (kept, left) = cutLine(text)
        #expect(kept.utf16.count == ContentLimits.lineWidth - 1)
        #expect(left == 4)
        #expect(AdmittedLines(Data(text.utf8)).cut == [0: 4])
    }

    @Test func theStartOfContentsLeavesOutItsPartialLastLine() {
        let start = Data("one\ntwo\nthr".utf8)
        #expect(AdmittedLines(start, complete: false).lines == ["one", "two"])
        #expect(AdmittedLines(Data("only part".utf8), complete: false).lines == ["only part"])
        #expect(AdmittedLines(start, limit: 1).lines == ["one"])
    }

    @Test func aPatchTooLongToTakeInKeepsItsFirstLinesAndCountsTheRest() {
        let added = ContentLimits.wholeLines + 5
        var patch: [ArraySlice<UInt8>] = ["diff --git a/f b/f", "@@ -0,0 +1,\(added) @@"].map { ArraySlice(Array($0.utf8)) }
        for i in 0..<added { patch.append(ArraySlice(Array("+line \(i)".utf8))) }
        let change = RawChange(status: "A", oldMode: "000000", newMode: "100644", oldOid: zeroOid, newOid: "1", oldPath: "f", path: "f")
        let diff = parseFilePatch(patch, change: change)
        #expect(diff.lineCount == ContentLimits.previewLines)
        #expect(diff.omittedLines == added - ContentLimits.previewLines)
        #expect(diff.additions == added)
        #expect(!diff.hunksAreWholeFile)
    }

    @Test func aPatchLineTooWideIsCut() {
        let wide = String(repeating: "x", count: ContentLimits.lineWidth + 123)
        let patch = ["diff --git a/f b/f", "@@ -1 +1 @@", "-a", "+" + wide + "\r"].map { ArraySlice(Array($0.utf8)) }
        let change = RawChange(status: "M", oldMode: "100644", newMode: "100644", oldOid: "1", newOid: "2", oldPath: "f", path: "f")
        let line = parseFilePatch(patch, change: change).hunks[0].lines[1]
        #expect(line.text.utf16.count == ContentLimits.lineWidth)
        #expect(line.cut == 123)
        #expect(line.carriageReturn)
    }

    @Test func runsOfCutLinesThatDifferOnlyPastTheCutHaveTheirOwnKeys() {
        let run = ChangeRun(lines: 0..<1, additions: 1, deletions: 0, newLine: 0)
        let a = DiffLine(kind: .added, oldNo: 0, newNo: 1, text: "same", cut: 5)
        let b = DiffLine(kind: .added, oldNo: 0, newNo: 1, text: "same", cut: 6)
        #expect(changeKeys([a], runs: [run]) != changeKeys([b], runs: [run]))
    }

    @Test func admissionsAreRememberedByBlobIDWithinTheirCapacity() {
        let admissions = Admissions(capacity: 2)
        let small = Admission(bytes: 1, lines: 1, longestLine: 1)
        admissions.record(small, for: "a")
        admissions.record(small, for: "b")
        _ = admissions["a"]
        admissions.record(small, for: "c")
        #expect(admissions["a"] == small)
        #expect(admissions["b"] == nil)
        #expect(admissions["c"] == small)
        admissions.record(small, for: zeroOid)
        #expect(admissions[zeroOid] == nil)
    }
}

/// Repositories holding pathological files, read the way the app reads them.
@Suite(.serialized) struct AdmissionIntegrationTests {
    /// Writes a file of many short lines, quickly.
    private func writeLines(_ r: ScratchRepo, _ path: String, count: Int, changing: Set<Int> = []) throws {
        var out = Data()
        out.reserveCapacity(count * 16)
        for i in 0..<count { out.append(contentsOf: (changing.contains(i) ? "int v\(i) = -\(i);\n" : "int v\(i) = \(i);\n").utf8) }
        try out.write(to: r.root.appendingPathComponent(path))
    }

    @Test func aFileWithTooManyLinesShowsOnlyItsChangesAndIsReadOnce() async throws {
        let r = try ScratchRepo("admission-lines")
        try writeLines(r, "big.c", count: ContentLimits.wholeLines + 10)
        try r.git("add", "-A")
        try r.git("commit", "-qm", "base")
        try writeLines(r, "big.c", count: ContentLimits.wholeLines + 10, changing: [7, 400_000])
        let diff = try #require(try await r.repo.diff(.worktree(since: nil)).first)
        #expect(diff.hunks.count == 2)
        guard case .partial(let admission, let start)? = await r.repo.whole(of: diff) else { Issue.record("read whole"); return }
        #expect(admission.lines == ContentLimits.wholeLines + 10)
        #expect(admission.verdict == .preview)
        #expect(start == nil)
        #expect(Admissions.shared[diff.change.oldOid] == admission)
        #expect(try await r.repo.oldLines(of: diff) == nil)
    }

    @Test func aFileTooLargeToCompareShowsItsStart() async throws {
        let r = try ScratchRepo("admission-huge")
        let line = Data("0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef\n".utf8)
        var huge = Data()
        huge.reserveCapacity(ContentLimits.wholeBytes + line.count * 2)
        while huge.count <= ContentLimits.wholeBytes { huge.append(line) }
        try Data("small\n".utf8).write(to: r.root.appendingPathComponent("huge.txt"))
        try r.write("binary.bin", "small\n")
        try r.git("add", "-A")
        try r.git("commit", "-qm", "base")
        try huge.write(to: r.root.appendingPathComponent("huge.txt"))
        var binary = huge
        binary[10] = 0
        try binary.write(to: r.root.appendingPathComponent("binary.bin"))
        try r.git("add", "-A")
        try r.git("commit", "-qm", "huge")
        let files = try await r.repo.diff(.commit(try r.git("rev-parse", "HEAD")))
        let text = try #require(files.first { $0.path == "huge.txt" })
        #expect(!text.isBinary)
        #expect(text.uncomparedSize == huge.count)
        #expect(text.hunks.isEmpty)
        guard case .partial(let admission, let start?)? = await r.repo.whole(of: text) else { Issue.record("read whole"); return }
        #expect(admission.bytes == huge.count)
        #expect(admission.verdict == .preview)
        #expect(!admission.isBinary)
        #expect(start.lines.count == min(ContentLimits.previewLines, ContentLimits.previewBytes / line.count))
        #expect(start.lines.allSatisfy { $0.utf8.count == line.count - 1 })
        let bin = try #require(files.first { $0.path == "binary.bin" })
        #expect(bin.uncomparedSize == binary.count)
        guard case .partial(let binaryAdmission, _)? = await r.repo.whole(of: bin) else { Issue.record("read binary"); return }
        #expect(binaryAdmission.isBinary)
        guard case .start(let data, let size)? = await r.repo.read("huge.txt", in: .commit(try r.git("rev-parse", "HEAD"))) else {
            Issue.record("read in a commit")
            return
        }
        #expect(size == huge.count)
        #expect(data.count == ContentLimits.previewBytes)
        guard case .start(let worktreeData, let worktreeSize)? = await r.repo.read("huge.txt", in: .worktree) else {
            Issue.record("read in the worktree")
            return
        }
        #expect(worktreeSize == huge.count)
        #expect(worktreeData.count == ContentLimits.previewBytes)
    }

    @Test func aMinifiedLineIsCutAndLeavesTheFilePlain() async throws {
        let r = try ScratchRepo("admission-minified")
        let line = String(repeating: "var a=function(b){return b};", count: 2_000)
        try r.write("app.min.js", line + "\n")
        try r.git("add", "-A")
        try r.git("commit", "-qm", "base")
        try r.write("app.min.js", line + "x\n")
        let diff = try #require(try await r.repo.diff(.worktree(since: nil)).first)
        #expect(diff.hunks[0].lines.map(\.cut) == [line.utf16.count - ContentLimits.lineWidth, line.utf16.count + 1 - ContentLimits.lineWidth])
        guard case .lines(let all)? = await r.repo.whole(of: diff) else { Issue.record("read whole"); return }
        #expect(all.allSatisfy { $0.text.utf16.count == ContentLimits.lineWidth && $0.cut > 0 })
        #expect(Admissions.shared[diff.change.oldOid]?.verdict == .plain)
    }

    @Test func aFileTooLargeToAnalyzeIsReadOnceForItsDefinitions() async throws {
        let r = try ScratchRepo("admission-index")
        var big = ""
        while big.utf8.count <= ContentLimits.analysisBytes { big += "func f\(big.utf8.count)() {}\n" }
        try r.write("big.swift", big)
        try r.write("small.swift", "func small() {}\n")
        try r.git("add", "-A")
        try r.git("commit", "-qm", "base")
        let head = try r.git("rev-parse", "HEAD")
        let index = DefinitionIndex(analysis: ContentAnalysis(cache: nil))
        let found = try await index.definitions(in: .commit(head), git: r.repo)
        #expect(found.map(\.path) == ["small.swift"])
        let oid = try r.git("rev-parse", "HEAD:big.swift")
        #expect(Admissions.shared[oid]?.analyzes == false)
        #expect(Admissions.shared[oid]?.bytes == big.utf8.count)
    }
}
