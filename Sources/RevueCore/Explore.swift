import Foundation

/// Parses `git grep -n -z --column` output.
///
/// - Parameter revisionPrefix: The revision that a revision search prefixes each path with,
///   as `<rev>:`, or nil for a search without that prefix.
public func parseGrepZ(_ data: Data, revisionPrefix: String?) -> [GrepMatch] {
    var out: [GrepMatch] = []
    for record in data.split(separator: 0x0A, omittingEmptySubsequences: true) {
        let f = record.split(separator: 0, maxSplits: 3, omittingEmptySubsequences: false)
        guard f.count == 4, let line = Int(String(decoding: f[1], as: UTF8.self)),
              let col = Int(String(decoding: f[2], as: UTF8.self)) else { continue }
        var path = String(decoding: f[0], as: UTF8.self)
        if let p = revisionPrefix, path.hasPrefix(p + ":") { path.removeFirst(p.count + 1) }
        let raw = f[3].last == 0x0D ? f[3].dropLast() : f[3]
        out.append(GrepMatch(path: path, line: line, column: col, text: String(decoding: raw, as: UTF8.self)))
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
        case .worktree: try await run(["ls-files", "-z", "--cached", "--others", "--exclude-standard", "--deduplicate"])
        case .index: try await run(["ls-files", "-z", "--cached"])
        case .commit(let c): try await run(["ls-tree", "-r", "-z", "--name-only", c])
        }
        var paths = data.split(separator: 0).map { String(decoding: $0, as: UTF8.self) }
        if snapshot == .worktree {
            let fm = FileManager.default
            paths.removeAll { !fm.fileExists(atPath: root.appendingPathComponent($0).path) }
        }
        return paths
    }

    /// A file's contents in a snapshot, or nil if it doesn't exist there.
    public func contents(of path: String, in snapshot: Snapshot) async -> Data? {
        switch snapshot {
        case .worktree: readWorktreeFile(path)
        case .index: try? await run(["cat-file", "blob", ":" + path])
        case .commit(let c):
            ObjectReader.canRead(c + ":" + path) ? await objects.blob(c + ":" + path) : try? await run(["cat-file", "blob", c + ":" + path])
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
        let data = try await Git.run(executable, in: root, args, allowedStatuses: [0, 1])
        return parseGrepZ(data, revisionPrefix: prefix)
    }

    public func blame(_ path: String, in snapshot: Snapshot) async throws -> Blame {
        let data: Data = switch snapshot {
        case .worktree: try await run(["blame", "--porcelain", "--", path])
        case .index:
            try await run(["blame", "--porcelain", "--contents", "-", "--", path], stdin: try await run(["cat-file", "blob", ":" + path]))
        case .commit(let c): try await run(["blame", "--porcelain", c, "--", path])
        }
        return parseBlamePorcelain(data)
    }

    /// Commits that touched a path, newest first, following renames.
    public func history(of path: String, from ref: String, count: Int) async throws -> [Commit] {
        let data = try await run(["log", "--format=" + logFormat, "--raw", "--no-abbrev", "-M", "--follow", "-n", "\(count)", ref, "--", path])
        return parseLog(data)
    }
}
