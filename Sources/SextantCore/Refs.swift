import Foundation

/// A checkout of the repository: the main one or a linked worktree.
public struct Worktree: Sendable, Hashable {
    public var root: CanonicalPath
    /// The checked-out commit, or nil before the first commit.
    public var head: String?
    /// The checked-out branch's short name, or nil when HEAD is detached.
    public var branch: String?

    public init(root: CanonicalPath, head: String?, branch: String?) {
        self.root = root
        self.head = head
        self.branch = branch
    }

    public var name: String { root.name }
}

/// Parses `git worktree list --porcelain -z`, leaving out bare and prunable entries.
public func parseWorktreeList(_ data: Data) -> [Worktree] {
    var out: [Worktree] = []
    var current: Worktree?
    var skip = false
    func flush() {
        if let c = current, !skip { out.append(c) }
        current = nil
        skip = false
    }
    for field in data.split(separator: 0, omittingEmptySubsequences: false) {
        let s = String(decoding: field, as: UTF8.self)
        if s.isEmpty { flush(); continue }
        if s.hasPrefix("worktree ") {
            flush()
            current = Worktree(root: CanonicalPath(path: String(s.dropFirst(9))), head: nil, branch: nil)
        } else if s.hasPrefix("HEAD ") {
            let oid = String(s.dropFirst(5))
            current?.head = oid == zeroOid ? nil : oid
        } else if s.hasPrefix("branch ") {
            let ref = String(s.dropFirst(7))
            current?.branch = ref.hasPrefix("refs/heads/") ? String(ref.dropFirst(11)) : ref
        } else if s == "bare" || s.hasPrefix("prunable") {
            skip = true
        }
    }
    flush()
    return out
}

/// A local or remote-tracking branch.
public struct Branch: Sendable, Hashable {
    /// The short name, such as `feature/x` or `origin/feature/x`.
    public var name: String
    public var isRemote: Bool
    public var oid: String
    public var date: Date
    public var subject: String
    /// Commits on the branch and not on the base it was listed against.
    public var ahead: Int?
    /// Commits on the base and not on the branch.
    public var behind: Int?

    public init(name: String, isRemote: Bool, oid: String, date: Date, subject: String, ahead: Int?, behind: Int?) {
        self.name = name
        self.isRemote = isRemote
        self.oid = oid
        self.date = date
        self.subject = subject
        self.ahead = ahead
        self.behind = behind
    }
}

/// The `git for-each-ref` format that `parseBranches` reads, comparing against `base`.
public func branchFormat(base: String?) -> String {
    "%(refname)%00%(symref)%00%(objectname)%00%(committerdate:unix)%00\(base.map { "%(ahead-behind:\($0))" } ?? "")%00%(subject)"
}

/// Parses `git for-each-ref` output in `branchFormat`, leaving out symbolic refs like `origin/HEAD`.
public func parseBranches(_ data: Data) -> [Branch] {
    data.split(separator: 0x0A).compactMap { line in
        let f = line.split(separator: 0, maxSplits: 5, omittingEmptySubsequences: false).map { String(decoding: $0, as: UTF8.self) }
        guard f.count == 6, f[1].isEmpty else { return nil }
        let ref = f[0]
        let isRemote = ref.hasPrefix("refs/remotes/")
        guard ref.hasPrefix("refs/heads/") || isRemote else { return nil }
        let name = String(ref.dropFirst(isRemote ? 13 : 11))
        let counts = f[4].split(separator: " ").compactMap { Int($0) }
        return Branch(name: name, isRemote: isRemote, oid: f[2], date: Date(timeIntervalSince1970: TimeInterval(f[3]) ?? 0), subject: f[5],
                      ahead: counts.count == 2 ? counts[0] : nil, behind: counts.count == 2 ? counts[1] : nil)
    }
}

/// An open pull request on the repository's hosting service, as `gh` reports it.
public struct PullRequest: Sendable, Hashable, Decodable {
    public struct Author: Sendable, Hashable, Decodable {
        public var login: String
    }

    public var number: Int
    public var title: String
    public var headRefName: String
    public var headRefOid: String
    public var baseRefName: String
    public var isDraft: Bool
    public var author: Author
    public var updatedAt: Date

    /// The fields to ask `gh pr list --json` for.
    public static let fields = "number,title,headRefName,headRefOid,baseRefName,isDraft,author,updatedAt"
}

/// Parses `gh pr list --json` output.
public func parsePullRequests(_ data: Data) throws -> [PullRequest] {
    let d = JSONDecoder()
    d.dateDecodingStrategy = .iso8601
    return try d.decode([PullRequest].self, from: data)
}

/// What's uncommitted and conflicted in a worktree, as `git status` gives it.
public struct WorktreeStatus: Sendable, Hashable {
    /// The number of paths that aren't committed, untracked files included.
    public var count = 0
    /// The paths with merge conflicts.
    public var conflicts: Set<String> = []
}

extension Git {
    /// Reads what's uncommitted and conflicted in the worktree.
    ///
    /// - Throws: When git can't give the status, such as for a damaged index, so a worktree
    ///   it can't read isn't taken for a clean one.
    public func status() async throws -> WorktreeStatus {
        let data = try await run(["status", "--porcelain=v1", "-z", "--untracked-files=all", "--no-renames", "--ignore-submodules=dirty"], priority: .utility)
        var s = WorktreeStatus()
        for entry in data.split(separator: 0) where entry.count >= 3 {
            s.count += 1
            let x = Character(UnicodeScalar(entry[entry.startIndex])), y = Character(UnicodeScalar(entry[entry.startIndex + 1]))
            if x == "U" || y == "U" || (x == "A" && y == "A") || (x == "D" && y == "D") {
                s.conflicts.insert(String(decoding: entry.dropFirst(3), as: UTF8.self))
            }
        }
        return s
    }

    public func worktrees() async -> [Worktree] {
        guard let data = try? await run(["worktree", "list", "--porcelain", "-z"]) else { return [] }
        return parseWorktreeList(data)
    }

    /// Local and remote-tracking branches, most recently committed first, with their distance
    /// from `base`.
    public func branches(comparedWith base: String?) async -> [Branch] {
        guard let data = try? await run(["for-each-ref", "--sort=-committerdate", "--format=" + branchFormat(base: base), "refs/heads", "refs/remotes"]) else { return [] }
        return parseBranches(data)
    }

    /// Whether a commit is in the object database.
    public func hasCommit(_ oid: String) async -> Bool {
        (try? await run(["cat-file", "-e", oid + "^{commit}"])) != nil
    }

    /// Fetches a pull request's head commit from `remote` without creating or moving any ref.
    public func fetchPullRequest(_ number: Int, remote: String = "origin") async throws {
        try await run(["fetch", "--quiet", "--no-tags", "--no-write-fetch-head", remote, "refs/pull/\(number)/head"])
    }

    /// Commits reachable from any branch or tag whose subject, author or hash matches `query`,
    /// newest first.
    public func searchCommits(_ query: String, limit: Int = 40) async -> [Commit] {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return [] }
        async let byText = try? run(["log", "--format=" + logFormat, "--branches", "--remotes", "--tags", "-i", "--fixed-strings",
                                     "--grep=" + q, "-n", "\(limit)"])
        async let byAuthor = try? run(["log", "--format=" + logFormat, "--branches", "--remotes", "--tags", "-i", "--fixed-strings",
                                       "--author=" + q, "-n", "\(limit / 2)"])
        var out: [Commit] = []
        if q.count >= 4, q.allSatisfy(\.isHexDigit), let oid = await resolve(q), let d = try? await run(["log", "--format=" + logFormat, "-n", "1", oid]) {
            out += parseLog(d)
        }
        out += parseLog(await byText ?? Data()) + parseLog(await byAuthor ?? Data())
        var seen = Set<String>()
        return out.filter { seen.insert($0.oid).inserted }.sorted { $0.date > $1.date }.prefix(limit).map { $0 }
    }
}

/// Lists open pull requests with the GitHub CLI.
///
/// - Parameters:
///   - root: A directory inside the repository.
///   - gh: The path to the `gh` executable.
///   - path: The PATH to run it with, so it can find git and its credential helpers.
/// - Throws: When `gh` is missing, signed out, or the repository isn't on GitHub.
public func listPullRequests(in root: URL, gh: String, path: String) async throws -> [PullRequest] {
    try await withCheckedThrowingContinuation { cont in
        DispatchQueue.global(qos: .utility).async {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: gh)
            p.arguments = ["pr", "list", "--state", "open", "--limit", "200", "--json", PullRequest.fields]
            p.qualityOfService = .utility
            p.currentDirectoryURL = root
            var env = ProcessInfo.processInfo.environment
            env["PATH"] = path
            env["GH_PROMPT_DISABLED"] = "1"
            env["NO_COLOR"] = "1"
            p.environment = env
            let out = Pipe()
            p.standardOutput = out
            p.standardError = FileHandle.nullDevice
            p.standardInput = FileHandle.nullDevice
            do { try p.run() } catch { cont.resume(throwing: error); return }
            let data = out.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            guard p.terminationStatus == 0 else { cont.resume(throwing: GitError(message: "gh pr list failed")); return }
            do { cont.resume(returning: try parsePullRequests(data)) } catch { cont.resume(throwing: error) }
        }
    }
}
