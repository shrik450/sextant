import Foundation

/// Parses `git grep -n -z --column` output.
///
/// Each match is a path, line and column, each ended by NUL, then the line's text ended by LF.
/// They're read in that order, since a path can hold an LF and the text can hold a NUL.
///
/// - Parameter revisionPrefix: The revision that a revision search prefixes each path with,
///   as `<rev>:`, or nil for a search without that prefix.
public func parseGrepZ(_ data: Data, revisionPrefix: String?) -> [GrepMatch] {
    let bytes = [UInt8](data)
    var out: [GrepMatch] = []
    var i = 0
    func field(endingAt end: UInt8) -> ArraySlice<UInt8>? {
        guard i < bytes.count else { return nil }
        let start = i
        while i < bytes.count, bytes[i] != end { i += 1 }
        defer { i += 1 }
        return bytes[start..<i]
    }
    while let rawPath = field(endingAt: 0), let lineField = field(endingAt: 0), let colField = field(endingAt: 0), let text = field(endingAt: 0x0A) {
        guard let line = Int(String(decoding: lineField, as: UTF8.self)), let col = Int(String(decoding: colField, as: UTF8.self)) else { continue }
        var path = String(decoding: rawPath, as: UTF8.self)
        if let p = revisionPrefix, path.hasPrefix(p + ":") { path.removeFirst(p.count + 1) }
        out.append(GrepMatch(path: path, line: line, column: col, text: String(decoding: text.last == 0x0D ? text.dropLast() : text, as: UTF8.self)))
    }
    return out
}

/// Parses `git blame --porcelain`.
public func parseBlamePorcelain(_ data: Data) -> Blame {
    var lines: [String] = []
    var commits: [String: Blame.Commit] = [:]
    var current = ""
    var pending: (author: String, time: Date, summary: String) = ("", Date(timeIntervalSince1970: 0), "")
    var expectHeader = true
    for raw in data.split(separator: 0x0A, omittingEmptySubsequences: false) {
        if raw.first == 0x09 {
            if commits[current] == nil {
                commits[current] = Blame.Commit(oid: current, author: pending.author, date: pending.time, summary: pending.summary)
            }
            lines.append(current)
            expectHeader = true
            continue
        }
        let s = String(decoding: raw, as: UTF8.self)
        if expectHeader {
            guard let sp = s.firstIndex(of: " ") else { continue }
            current = String(s[..<sp])
            expectHeader = false
            if commits[current] == nil { pending = ("", Date(timeIntervalSince1970: 0), "") }
            continue
        }
        if s.hasPrefix("author ") { pending.author = String(s.dropFirst(7)) }
        else if s.hasPrefix("author-time ") { pending.time = Date(timeIntervalSince1970: TimeInterval(s.dropFirst(12)) ?? 0) }
        else if s.hasPrefix("summary ") { pending.summary = String(s.dropFirst(8)) }
    }
    return Blame(lines: lines, commits: commits)
}

extension Git {
    /// Every file in a snapshot, as repository-relative paths.
    public func files(in snapshot: Snapshot) async throws -> [String] {
        let data: Data = switch snapshot {
        case .worktree: try await run(["ls-files", "-z", "--cached", "--others", "--exclude-standard", "--deduplicate"], limit: Limit.listing)
        case .index: try await run(["ls-files", "-z", "--cached"], limit: Limit.listing)
        case .commit(let c): try await run(["ls-tree", "-r", "-z", "--name-only", c], limit: Limit.listing)
        }
        var paths = data.split(separator: 0).map { String(decoding: $0, as: UTF8.self) }
        if snapshot == .worktree {
            let fm = FileManager.default
            paths.removeAll { !fm.fileExists(atPath: root.appendingPathComponent($0).path) }
        }
        return paths
    }

    /// A file's contents in a snapshot, or nil if it doesn't exist there, or is too large to show
    /// whole.
    public func contents(of path: String, in snapshot: Snapshot) async -> Data? {
        guard case .whole(let data)? = await read(path, in: snapshot) else { return nil }
        return data
    }

    /// What reading a file in a snapshot found.
    public enum SnapshotRead: Sendable {
        case whole(Data)
        /// The file is larger than `ContentLimits.wholeBytes`, so only its start is read, up to
        /// `ContentLimits.previewBytes`.
        case start(Data, size: Int)
    }

    /// Reads a file in a snapshot whole, or only its start when it's too large to show whole.
    ///
    /// - Returns: Nil if the file doesn't exist in the snapshot or can't be read.
    public func read(_ path: String, in snapshot: Snapshot) async -> SnapshotRead? {
        let name: String
        switch snapshot {
        case .worktree:
            guard let read = readWorktreeStart(path, limit: Limit.blob) else { return nil }
            if read.complete { return .whole(read.data) }
            return .start(read.data.prefix(ContentLimits.previewBytes), size: worktreeSize(path) ?? read.data.count)
        case .index: name = ":" + path
        case .commit(let c): name = c + ":" + path
        }
        do {
            return .whole(ObjectReader.canRead(name) ? try await blob(name) : try await run(["cat-file", "blob", name], limit: Limit.blob))
        } catch let e as GitError where e.reason == .outputTooLarge(limit: Limit.blob) {
            guard let start = try? await Git.runStart(executable, in: root, ["cat-file", "blob", name], limit: ContentLimits.previewBytes) else { return nil }
            return .start(start.data, size: e.size ?? Limit.blob + 1)
        } catch {
            return nil
        }
    }

    /// Searches a snapshot for a literal string.
    ///
    /// - Parameter word: Whether to match whole identifiers only.
    public func grep(_ needle: String, in snapshot: Snapshot, word: Bool, ignoreCase: Bool, maxPerFile: Int = 200) async throws -> [GrepMatch] {
        var args = ["grep", "-n", "-z", "--column", "-I", "--no-color", "-F", "--max-count=\(maxPerFile)"]
        if word { args.append("-w") }
        if ignoreCase { args.append("-i") }
        var prefix: String?
        switch snapshot {
        case .worktree: args.append("--untracked")
        case .index: args.append("--cached")
        case .commit: break
        }
        args += ["-e", needle]
        if case .commit(let c) = snapshot {
            args.append(c)
            prefix = c
        }
        args.append("--")
        let data = try await Git.run(executable, in: root, args, allowedStatuses: [0, 1], limit: Limit.listing)
        return parseGrepZ(data, revisionPrefix: prefix)
    }

    public func blame(_ path: String, in snapshot: Snapshot) async throws -> Blame {
        let data: Data = switch snapshot {
        case .worktree: try await run(["blame", "--porcelain", "--", path], limit: Limit.listing)
        case .index:
            try await run(["blame", "--porcelain", "--contents", "-", "--", path], stdin: try await run(["cat-file", "blob", ":" + path], limit: Limit.blob), limit: Limit.listing)
        case .commit(let c): try await run(["blame", "--porcelain", c, "--", path], limit: Limit.listing)
        }
        return parseBlamePorcelain(data)
    }

    /// Commits that touched a path, newest first, following renames.
    public func history(of path: String, from ref: String, count: Int) async throws -> [Commit] {
        let data = try await run(["log", "--format=" + logFormat, "--raw", "--no-abbrev", "-M", "--follow", "-n", "\(count)", ref, "--", path], limit: Limit.listing)
        return parseLog(data)
    }
}
