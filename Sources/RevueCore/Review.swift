import Foundation

/// What the user chose to review.
public enum Subject: Sendable, Hashable {
    /// All the work in a checkout: its branch's commits since the base, plus whatever isn't
    /// committed yet.
    case worktree(URL)
    /// A local or remote-tracking branch, since it split from the base.
    case branch(String)
    /// An open pull request, since its head split from the base.
    case pullRequest(Int)
    /// One commit, against its first parent.
    case commit(String)
    /// Two revisions, compared directly (`from..to`) or since their common ancestor (`from...to`).
    case comparison(from: String, to: String, sinceAncestor: Bool)
    case stash(String)

    /// Whether the subject is compared with a base the user can change.
    public var hasBase: Bool {
        switch self {
        case .worktree, .branch, .pullRequest: true
        default: false
        }
    }

    /// A string that names the subject, for keeping things like notes and bases with it.
    public var key: String {
        switch self {
        case .worktree(let root): "worktree:" + root.standardizedFileURL.path
        case .branch(let b): "branch:" + b
        case .pullRequest(let n): "pr:\(n)"
        case .commit(let c): "commit:" + c
        case .comparison(let a, let b, let since): "compare:" + a + (since ? "..." : "..") + b
        case .stash(let s): "stash:" + s
        }
    }
}

/// The part of a review being read.
public enum Scope: Sendable, Hashable {
    case everything
    /// A worktree's changes that aren't committed yet.
    case uncommitted
    case staged
    case unstaged
    /// A run of the subject's own commits, from `oldest` to `newest` inclusive.
    case commits(newest: String, oldest: String)
}

/// A subject, the base it's compared with, and the part being read.
public struct Review: Sendable, Hashable {
    public var subject: Subject
    /// The ref the subject is compared with, for subjects that have one.
    public var base: String?
    public var scope: Scope

    public init(subject: Subject, base: String? = nil, scope: Scope = .everything) {
        self.subject = subject
        self.base = base
        self.scope = scope
    }
}

/// What a typed revision expression asks for.
public enum RevisionSpec: Sendable, Equatable {
    case uncommitted
    case staged
    case unstaged
    case pullRequest(Int)
    case comparison(from: String, to: String, sinceAncestor: Bool)
    /// A single revision: a branch, tag, stash or commit, to be told apart by looking it up.
    case revision(String)
}

/// Reads a revision expression as `git diff` would, plus `#123` for a pull request.
///
/// - Returns: Nil for an empty expression.
public func parseRevisionSpec(_ text: String) -> RevisionSpec? {
    let s = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !s.isEmpty else { return nil }
    switch s.lowercased() {
    case "uncommitted", "worktree", "working", "wip": return .uncommitted
    case "staged", "cached", "--staged", "--cached", "index": return .staged
    case "unstaged": return .unstaged
    default: break
    }
    if s.hasPrefix("#"), let n = Int(s.dropFirst()), n > 0 { return .pullRequest(n) }
    for (separator, since) in [("...", true), ("..", false)] {
        if let r = s.range(of: separator) {
            let from = String(s[..<r.lowerBound]), to = String(s[r.upperBound...])
            return .comparison(from: from.isEmpty ? "HEAD" : from, to: to.isEmpty ? "HEAD" : to, sinceAncestor: since)
        }
    }
    return .revision(s)
}

/// A review with its refs looked up: where to run git, the subject's commits, and the diff to load.
public struct ResolvedReview: Sendable {
    public var review: Review
    /// The git to run reads and diffs with, rooted in the subject's worktree when it has one.
    public var git: Git
    public var worktree: Worktree?
    public var pullRequest: PullRequest?
    /// The subject's head commit, or nil for an empty worktree.
    public var head: String?
    /// Where the subject split from its base.
    public var mergeBase: String?
    /// The subject's own commits, newest first.
    public var commits: [Commit]
    public var target: Target
}

/// Looks up the refs a review names and decides what to diff.
public struct Resolver: Sendable {
    public let git: Git

    public init(git: Git) { self.git = git }

    public func resolve(_ review: Review, worktrees: [Worktree], pullRequests: [PullRequest]) async throws -> ResolvedReview {
        var review = review
        var worktree: Worktree?
        var pr: PullRequest?
        var runIn = git
        let head: String?
        switch review.subject {
        case .worktree(let root):
            let std = root.standardizedFileURL
            runIn = Git(root: root, executable: git.executable)
            head = await runIn.head()
            if let known = worktrees.first(where: { $0.root.standardizedFileURL == std }) {
                worktree = known
            } else {
                worktree = Worktree(root: root, head: head, branch: await runIn.currentBranch())
            }
        case .branch(let name):
            guard let oid = await git.resolve(name) else { throw GitError(message: "There’s no branch named ‘\(name)’") }
            head = oid
        case .pullRequest(let n):
            guard let p = pullRequests.first(where: { $0.number == n }) else { throw GitError(message: "Pull request #\(n) isn’t open") }
            pr = p
            if !(await git.hasCommit(p.headRefOid)) { try await git.fetchPullRequest(n) }
            head = p.headRefOid
            if review.base == nil, await git.resolve("origin/" + p.baseRefName) != nil { review.base = "origin/" + p.baseRefName }
        case .commit(let c):
            guard let oid = await git.resolve(c) else { throw GitError(message: "Unknown revision ‘\(c)’") }
            review.subject = .commit(oid)
            head = oid
        case .comparison(let from, let to, let since):
            async let fromR = git.resolve(from)
            async let toR = git.resolve(to)
            guard let f = await fromR else { throw GitError(message: "Unknown revision ‘\(from)’") }
            guard let t = await toR else { throw GitError(message: "Unknown revision ‘\(to)’") }
            let base: String
            if since {
                guard let mb = await git.mergeBase(f, t) else { throw GitError(message: "‘\(from)’ and ‘\(to)’ have no common ancestor") }
                base = mb
            } else {
                base = f
            }
            let commits = (try? await git.log("\(base)..\(t)", skip: 0, count: 1000)) ?? []
            return ResolvedReview(review: review, git: git, head: t, mergeBase: base, commits: commits,
                                  target: scoped(review.scope, everything: .range(base: base, head: t), commits: commits))
        case .stash(let s):
            return ResolvedReview(review: review, git: git, head: s, commits: [], target: .stash(s))
        }

        var mergeBase: String?
        if review.subject.hasBase, let base = review.base, let head {
            mergeBase = await git.mergeBase(base, head)
        }
        var commits: [Commit] = []
        if let mergeBase, let head, mergeBase != head {
            commits = (try? await git.log("\(mergeBase)..\(head)", skip: 0, count: 1000)) ?? []
        }
        let everything: Target = switch review.subject {
        case .worktree: .worktree(since: mergeBase)
        case .commit(let c): .commit(c)
        default: head.map { h in mergeBase.map { .range(base: $0, head: h) } ?? .commit(h) } ?? .worktree(since: nil)
        }
        if case .commit = review.subject { review.scope = .everything }
        return ResolvedReview(review: review, git: runIn, worktree: worktree, pullRequest: pr, head: head, mergeBase: mergeBase,
                              commits: commits, target: scoped(review.scope, everything: everything, commits: commits))
    }
}

/// Decides what to diff for part of a review.
///
/// - Parameters:
///   - everything: The diff for the whole subject.
///   - commits: The subject's own commits, newest first, which a commit scope refers to.
public func scoped(_ scope: Scope, everything: Target, commits: [Commit]) -> Target {
    switch scope {
    case .everything:
        return everything
    case .uncommitted:
        return .worktree(since: nil)
    case .staged:
        return .staged
    case .unstaged:
        return .unstaged
    case .commits(let newest, let oldest):
        if newest == oldest { return .commit(newest) }
        let parent = commits.first { $0.oid == oldest }?.parents.first ?? emptyTreeOid
        return .range(base: parent, head: newest)
    }
}
