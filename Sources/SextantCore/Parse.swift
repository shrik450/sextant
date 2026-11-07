import Foundation

/// Undoes git's C-style path quoting (`"tab\tname"`, octal escapes for raw bytes).
public func unquoteGitPath(_ s: Substring) -> String {
    guard s.count >= 2, s.first == "\"", s.last == "\"" else { return String(s) }
    var bytes: [UInt8] = []
    var it = Array(s.utf8.dropFirst().dropLast())[...]
    while let c = it.popFirst() {
        guard c == UInt8(ascii: "\\"), let e = it.popFirst() else {
            bytes.append(c)
            continue
        }
        switch e {
        case UInt8(ascii: "n"): bytes.append(0x0A)
        case UInt8(ascii: "t"): bytes.append(0x09)
        case UInt8(ascii: "r"): bytes.append(0x0D)
        case UInt8(ascii: "a"): bytes.append(0x07)
        case UInt8(ascii: "b"): bytes.append(0x08)
        case UInt8(ascii: "f"): bytes.append(0x0C)
        case UInt8(ascii: "v"): bytes.append(0x0B)
        case UInt8(ascii: "0")...UInt8(ascii: "7"):
            var v = Int(e - UInt8(ascii: "0"))
            for _ in 0..<2 {
                guard let d = it.first, (UInt8(ascii: "0")...UInt8(ascii: "7")).contains(d) else { break }
                v = v * 8 + Int(d - UInt8(ascii: "0"))
                it.removeFirst()
            }
            bytes.append(UInt8(truncatingIfNeeded: v))
        default: bytes.append(e)
        }
    }
    return String(decoding: bytes, as: UTF8.self)
}

/// Parses the metadata part of a raw entry: `:100644 100644 <oid> <oid> R087`.
///
/// An unmerged path in the worktree gets a combined entry instead, with a mode and an ID for
/// each side and the result: `::100644 100644 100644 <oid> <oid> <oid> MM`. That becomes status
/// `U`, from our side to the result.
func parseRawMeta(_ meta: Substring) -> (status: Character, score: Int?, oldMode: String, newMode: String, oldOid: String, newOid: String)? {
    let parents = meta.prefix { $0 == ":" }.count
    let sides = parents + 1
    let parts = meta.dropFirst(parents).split(separator: " ")
    guard parents > 0, parts.count == 2 * sides + 1, let st = parts[2 * sides].first else { return nil }
    let combined = parents > 1
    return (combined ? "U" : st, combined ? nil : Int(parts[2 * sides].dropFirst()),
            String(parts[0]), String(parts[sides - 1]), String(parts[sides]), String(parts[2 * sides - 1]))
}

/// Parses `git diff --raw -p -z` output into file diffs.
///
/// Patches are matched to raw entries by path, since git leaves some entries without one (an
/// unmerged path, a change only in mode) and lists unmerged paths first. When an unmerged path
/// also has an entry against one side, as with `--ours`, the two become one unmerged file.
public func parseRawPatchZ(_ data: Data) -> [FileDiff] {
    let bytes = [UInt8](data)
    var i = 0
    var changes: [RawChange] = []

    func readField() -> Substring? {
        guard i < bytes.count else { return nil }
        let start = i
        while i < bytes.count, bytes[i] != 0 { i += 1 }
        let s = String(decoding: bytes[start..<i], as: UTF8.self)
        i += 1
        return Substring(s)
    }

    while i < bytes.count, bytes[i] == UInt8(ascii: ":") {
        guard let metaField = readField(), let m = parseRawMeta(metaField), let p1 = readField() else { break }
        var oldPath = String(p1), path = String(p1)
        if m.status == "R" || m.status == "C", let p2 = readField() {
            path = String(p2)
        } else {
            oldPath = path
        }
        changes.append(RawChange(status: m.status, score: m.score, oldMode: m.oldMode, newMode: m.newMode, oldOid: m.oldOid, newOid: m.newOid, oldPath: oldPath, path: path))
    }
    while i < bytes.count, bytes[i] == 0 || bytes[i] == UInt8(ascii: "\n") { i += 1 }

    let unmerged = Set(changes.lazy.filter { $0.status == "U" }.map(\.path))
    if !unmerged.isEmpty {
        let againstASide = Set(changes.lazy.filter { $0.status != "U" && unmerged.contains($0.path) }.map(\.path))
        changes = changes.compactMap { c in
            guard unmerged.contains(c.path) else { return c }
            if c.status == "U" { return againstASide.contains(c.path) ? nil : c }
            var c = c
            c.status = "U"
            return c
        }
    }

    var patches: [String: PatchChunk] = [:]
    for p in splitPatches(bytes[i...]) where patches[p.path] == nil { patches[p.path] = p }
    return changes.map { c in
        if let p = patches[c.path] { return parseFilePatch(p.lines, change: c) }
        return FileDiff(change: c, notes: c.status == "U" ? ["Unmerged"] : [])
    }
}

struct PatchChunk {
    /// The path on the new side, which the raw entry for it names.
    var path: String
    var lines: [ArraySlice<UInt8>]
}

func splitPatches(_ bytes: ArraySlice<UInt8>) -> [PatchChunk] {
    var chunks: [PatchChunk] = []
    var cur: [ArraySlice<UInt8>] = []
    var start = bytes.startIndex
    let diffGit = Array("diff --git ".utf8)
    let diffCC = Array("diff --cc ".utf8)
    let diffCombined = Array("diff --combined ".utf8)
    let unmerged = Array("* Unmerged path ".utf8)
    func flush() {
        if let first = cur.first, let path = patchPath(first, header: cur.dropFirst()) { chunks.append(PatchChunk(path: path, lines: cur)) }
        cur = []
    }
    func handle(_ line: ArraySlice<UInt8>) {
        if line.starts(with: diffGit) || line.starts(with: diffCC) || line.starts(with: diffCombined) {
            flush()
        } else if line.starts(with: unmerged) {
            flush()
            return
        }
        if !cur.isEmpty || line.starts(with: diffGit) || line.starts(with: diffCC) || line.starts(with: diffCombined) { cur.append(line) }
    }
    var idx = bytes.startIndex
    while idx < bytes.endIndex {
        if bytes[idx] == UInt8(ascii: "\n") {
            handle(bytes[start..<idx])
            start = idx + 1
        }
        idx += 1
    }
    if start < bytes.endIndex { handle(bytes[start..<bytes.endIndex]) }
    flush()
    return chunks
}

/// Returns the new-side path a patch is for, from its `diff --git a/<old> b/<new>` line, or the
/// `rename to` or `copy to` line in its header when the two paths differ.
///
/// The two paths in the first line are only told apart there when they're the same, since an
/// unquoted path can hold ` b/`. A combined patch's line names its one path.
func patchPath(_ first: ArraySlice<UInt8>, header: ArraySlice<ArraySlice<UInt8>>) -> String? {
    for line in header {
        if line.starts(with: [UInt8(ascii: "@"), UInt8(ascii: "@")]) { break }
        for prefix in ["rename to ", "copy to "] where line.starts(with: prefix.utf8) {
            return unquoteGitPath(Substring(String(decoding: line.dropFirst(prefix.utf8.count), as: UTF8.self)))
        }
    }
    let s = String(decoding: first, as: UTF8.self)
    for prefix in ["diff --cc ", "diff --combined "] where s.hasPrefix(prefix) {
        return unquoteGitPath(s.dropFirst(prefix.count))
    }
    let rest = Array(first.dropFirst("diff --git ".utf8.count))
    if rest.first == UInt8(ascii: "\"") {
        guard let close = closingQuote(rest, from: 0), close + 2 < rest.count else { return nil }
        let b = unquoteGitPath(Substring(String(decoding: rest[(close + 2)...], as: UTF8.self)))
        return b.hasPrefix("b/") ? String(b.dropFirst(2)) : nil
    }
    let half = (rest.count - 1) / 2
    guard rest.count % 2 == 1, rest.count > 5, rest[half] == UInt8(ascii: " "),
          rest[..<half].starts(with: "a/".utf8), rest[(half + 1)...].starts(with: "b/".utf8),
          rest[2..<half].elementsEqual(rest[(half + 3)...]) else { return nil }
    return String(decoding: rest[(half + 3)...], as: UTF8.self)
}

/// Returns the index of the quote that closes a C-quoted string opening at `open`.
func closingQuote(_ bytes: [UInt8], from open: Int) -> Int? {
    var i = open + 1
    while i < bytes.count {
        if bytes[i] == UInt8(ascii: "\\") { i += 2; continue }
        if bytes[i] == UInt8(ascii: "\"") { return i }
        i += 1
    }
    return nil
}

func parseHunkHeader(_ line: Substring) -> (Int, Int, Int, Int, String)? {
    let ats = line.prefix(while: { $0 == "@" }).count
    guard ats >= 2 else { return nil }
    let rest = line.dropFirst(ats)
    guard let close = rest.range(of: String(repeating: "@", count: ats)) else { return nil }
    let ranges = rest[..<close.lowerBound].split(separator: " ")
    var section = String(rest[close.upperBound...])
    if section.hasPrefix(" ") { section.removeFirst() }
    func parse(_ r: Substring) -> (Int, Int) {
        let body = r.dropFirst()
        let nums = body.split(separator: ",")
        let start = Int(nums.first ?? "0") ?? 0
        let count = nums.count > 1 ? (Int(nums[1]) ?? 1) : 1
        return (start, count)
    }
    guard let oldR = ranges.first(where: { $0.hasPrefix("-") }), let newR = ranges.last(where: { $0.hasPrefix("+") }) else { return nil }
    let o = parse(oldR), n = parse(newR)
    return (o.0, o.1, n.0, n.1, section)
}

/// Parses one file's patch.
///
/// A line's trailing CR is dropped, as `splitLines(_:)` drops it, so a line reads the same from
/// a patch as from its blob, and `DiffLine.carriageReturn` says it was there.
func parseFilePatch(_ lines: [ArraySlice<UInt8>], change: RawChange) -> FileDiff {
    var hunks: [Hunk] = []
    var notes: [String] = []
    var isBinary = false
    var cur: Hunk?
    var oldNo = 0, newNo = 0
    var prefixWidth = 1
    var inHeader = true
    let keep = lines.count > ContentLimits.wholeLines ? ContentLimits.previewLines : Int.max
    var kept = 0
    var omitted = (lines: 0, added: 0, deleted: 0)

    for raw in lines {
        if kept >= keep, !inHeader {
            switch raw.first {
            case UInt8(ascii: "+"): omitted.added += 1
            case UInt8(ascii: "-"): omitted.deleted += 1
            case UInt8(ascii: "@"), UInt8(ascii: "\\"): continue
            default: break
            }
            omitted.lines += 1
            continue
        }
        guard let first = raw.first else {
            if cur != nil {
                cur!.lines.append(DiffLine(kind: .context, oldNo: oldNo, newNo: newNo, text: ""))
                oldNo += 1; newNo += 1
            }
            continue
        }
        if first == UInt8(ascii: "@"), raw.starts(with: [UInt8(ascii: "@"), UInt8(ascii: "@")]) {
            let s = String(decoding: raw, as: UTF8.self)
            if let h = parseHunkHeader(Substring(s)) {
                if let c = cur { hunks.append(c) }
                cur = Hunk(oldStart: h.0, oldCount: h.1, newStart: h.2, newCount: h.3, section: h.4, lines: [])
                oldNo = h.0; newNo = h.2
                prefixWidth = s.prefix(while: { $0 == "@" }).count - 1
                inHeader = false
                continue
            }
        }
        if inHeader {
            let s = String(decoding: raw, as: UTF8.self)
            if s.hasPrefix("Binary files ") || s.hasPrefix("GIT binary patch") {
                isBinary = true
            } else if s.hasPrefix("old mode ") {
                notes.append(s)
            } else if s.hasPrefix("new mode ") {
                notes.append(s)
            } else if s.hasPrefix("Submodule ") {
                notes.append(s)
            }
            continue
        }
        guard cur != nil else { continue }
        if first == UInt8(ascii: "\\") {
            if !cur!.lines.isEmpty { cur!.lines[cur!.lines.count - 1].noNewline = true }
            continue
        }
        let prefix = raw.prefix(prefixWidth)
        let body = raw.dropFirst(prefixWidth)
        let carriageReturn = body.last == 0x0D
        let (text, left) = (carriageReturn ? body.dropLast() : body).withUnsafeBytes { admittedLine($0) }
        kept += 1
        if prefixWidth == 1 {
            switch first {
            case UInt8(ascii: "+"):
                cur!.lines.append(DiffLine(kind: .added, oldNo: 0, newNo: newNo, text: text)); newNo += 1
            case UInt8(ascii: "-"):
                cur!.lines.append(DiffLine(kind: .deleted, oldNo: oldNo, newNo: 0, text: text)); oldNo += 1
            default:
                cur!.lines.append(DiffLine(kind: .context, oldNo: oldNo, newNo: newNo, text: text)); oldNo += 1; newNo += 1
            }
        } else {
            if prefix.contains(UInt8(ascii: "-")) {
                cur!.lines.append(DiffLine(kind: .deleted, oldNo: 0, newNo: 0, text: text))
            } else if prefix.contains(UInt8(ascii: "+")) {
                cur!.lines.append(DiffLine(kind: .added, oldNo: 0, newNo: newNo, text: text)); newNo += 1
            } else {
                cur!.lines.append(DiffLine(kind: .context, oldNo: 0, newNo: newNo, text: text)); newNo += 1
            }
        }
        if carriageReturn { cur!.lines[cur!.lines.count - 1].carriageReturn = true }
        if left > 0 { cur!.lines[cur!.lines.count - 1].cut = left }
    }
    if let c = cur { hunks.append(c) }
    var diff = FileDiff(change: change, hunks: hunks, isBinary: isBinary, notes: notes)
    diff.omittedLines = omitted.lines
    diff.additions += omitted.added
    diff.deletions += omitted.deleted
    return diff
}

public let logFormat = "%x1e%H%x1f%P%x1f%an%x1f%ae%x1f%at%x1f%D%x1f%s"

/// Parses `git log --format=<logFormat> --raw`.
public func parseLog(_ data: Data) -> [Commit] {
    let text = String(decoding: data, as: UTF8.self)
    var commits: [Commit] = []
    for record in text.split(separator: "\u{1e}", omittingEmptySubsequences: true) {
        let lines = record.split(separator: "\n", omittingEmptySubsequences: true)
        guard let head = lines.first else { continue }
        let f = head.split(separator: "\u{1f}", omittingEmptySubsequences: false)
        guard f.count >= 7 else { continue }
        var changes: [RawChange] = []
        for l in lines.dropFirst() where l.hasPrefix(":") {
            if let c = parseRawLine(l) { changes.append(c) }
        }
        commits.append(Commit(
            oid: String(f[0]),
            parents: f[1].split(separator: " ").map(String.init),
            author: String(f[2]),
            email: String(f[3]),
            date: Date(timeIntervalSince1970: TimeInterval(f[4]) ?? 0),
            subject: f[6...].joined(separator: "\u{1f}"),
            refs: parseDecorations(f[5]),
            changes: changes))
    }
    return commits
}

/// Splits a `%D` decoration list into branch names and tags, dropping HEAD pointers.
///
/// For example, `HEAD -> main, origin/main, tag: v1.0` becomes `["main", "origin/main", "v1.0"]`.
public func parseDecorations(_ s: Substring) -> [String] {
    s.split(separator: ",").compactMap { part in
        var p = part.trimmingCharacters(in: .whitespaces)
        if p.hasPrefix("HEAD -> ") { p = String(p.dropFirst(8)) }
        if p.hasPrefix("tag: ") { p = String(p.dropFirst(5)) }
        if p == "HEAD" || p.hasSuffix("/HEAD") || p.isEmpty { return nil }
        return p
    }
}

/// Parses one newline-terminated raw line: `:100644 100644 a b M\tpath`.
public func parseRawLine(_ l: Substring) -> RawChange? {
    let fields = l.split(separator: "\t", omittingEmptySubsequences: false)
    guard fields.count >= 2, let m = parseRawMeta(fields[0]) else { return nil }
    let p1 = unquoteGitPath(fields[1])
    let p2 = fields.count > 2 ? unquoteGitPath(fields[2]) : p1
    return RawChange(status: m.status, score: m.score, oldMode: m.oldMode, newMode: m.newMode, oldOid: m.oldOid, newOid: m.newOid, oldPath: p1, path: p2)
}

/// Builds a diff for a file that git doesn't track yet.
public func untrackedFileDiff(path: String, oid: String, contents: Data?, mode: String = "100644") -> FileDiff {
    let change = RawChange(status: "?", oldMode: "000000", newMode: mode, oldOid: zeroOid, newOid: oid, oldPath: path, path: path)
    guard let contents else { return FileDiff(change: change, notes: ["Too large to show"]) }
    if contents.prefix(8000).contains(0) { return FileDiff(change: change, isBinary: true) }
    if contents.isEmpty { return FileDiff(change: change) }
    let endsWithNewline = contents.last == 0x0A
    let admission = Admission(measuring: contents)
    let kept = admission.lines > ContentLimits.wholeLines ? ContentLimits.previewLines : admission.lines
    let admitted = AdmittedLines(contents, limit: kept)
    var dl = admitted.lines.enumerated().map { DiffLine(kind: .added, oldNo: 0, newNo: $0.offset + 1, text: $0.element, cut: admitted.cut[$0.offset] ?? 0) }
    if !endsWithNewline, kept == admission.lines, !dl.isEmpty { dl[dl.count - 1].noNewline = true }
    let hunk = Hunk(oldStart: 0, oldCount: 0, newStart: 1, newCount: admission.lines, section: "", lines: dl)
    var diff = FileDiff(change: change, hunks: [hunk])
    diff.omittedLines = admission.lines - kept
    diff.additions = admission.lines
    diff.newSideInWorktree = true
    return diff
}

/// Builds a diff for a repository inside the worktree that git doesn't track, which git would
/// add as a submodule.
public func untrackedRepositoryDiff(path: String) -> FileDiff {
    let change = RawChange(status: "?", oldMode: "000000", newMode: gitlinkMode, oldOid: zeroOid, newOid: zeroOid, oldPath: path, path: path)
    return FileDiff(change: change, notes: ["Repository inside this one"])
}

/// Splits blob contents into lines the same way a patch would show them.
///
/// Splits on LF bytes (Swift treats CRLF as one Character, so String splitting misses it)
/// and drops the CR of CRLF endings.
public func splitLines(_ data: Data) -> [String] {
    var parts = data.split(separator: 0x0A, omittingEmptySubsequences: false)
    if parts.last?.isEmpty == true { parts.removeLast() }
    return parts.map { p in
        String(decoding: p.last == 0x0D ? p.dropLast() : p, as: UTF8.self)
    }
}
