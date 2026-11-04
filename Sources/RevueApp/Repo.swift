import Foundation
import RevueCore

/// A snapshot of a repository's refs and history, plus the git handle used to load diffs.
@MainActor
final class Repo {
    let git: Git
    let root: URL
    let commonDir: URL
    let reviews: ReviewStore

    var name: String { root.lastPathComponent }

    var head: String?
    var branch: String?
    var defaultBranch: String?
    /// The merge base of HEAD with the default branch, when HEAD is a different branch.
    var branchBase: String?
    var aheadCount = 0
    var commits: [Commit] = []
    var hasMoreCommits = true
    var stashes: [Stash] = []
    var status = WorktreeStatus()

    static let pageSize = 400

    init(location: Git.Location, gitPath: String) {
        git = Git(root: location.root, executable: gitPath)
        root = location.root
        commonDir = location.commonDir
        reviews = ReviewStore.shared(for: location.commonDir)
    }

    struct WorktreeStatus: Equatable {
        var uncommitted = 0
        var staged = 0
        var unstaged = 0
        var conflicted = 0
        var conflictedPaths: Set<String> = []
    }

    /// Reloads refs, worktree status, stashes and the first page of history.
    ///
    /// - Returns: Whether anything that the sidebar shows changed.
    @discardableResult
    func refresh() async throws -> Bool {
        let git = self.git
        async let headR = git.head()
        async let branchR = git.currentBranch()
        async let defaultR = git.defaultBranch()
        async let stashR = git.stashes()
        async let statusR = Repo.loadStatus(git)
        let newHead = await headR
        let newBranch = await branchR
        let newDefault = await defaultR

        var base: String?
        var ahead = 0
        if let newHead, let d = newDefault, let dOid = await git.resolve(d), dOid != newHead {
            let shortDefault = d.split(separator: "/").last.map(String.init)
            if newBranch == nil || newBranch != shortDefault {
                base = await git.mergeBase(d, newHead)
                if let base, base != newHead {
                    ahead = Int(await git.optionalString(["rev-list", "--count", "\(base)..\(newHead)"]) ?? "0") ?? 0
                } else {
                    base = nil
                }
            }
        }

        let count = max(Repo.pageSize, commits.count)
        let newCommits = newHead == nil ? [] : try await git.log("HEAD", skip: 0, count: count)
        let newStashes = await stashR
        let newStatus = await statusR

        let changed = newHead != head || newBranch != branch || newDefault != defaultBranch || base != branchBase
            || newCommits.map(\.oid) != commits.map(\.oid) || newCommits.map(\.refs) != commits.map(\.refs)
            || newStashes != stashes || newStatus != status
        head = newHead
        branch = newBranch
        defaultBranch = newDefault
        branchBase = base
        aheadCount = ahead
        commits = newCommits
        hasMoreCommits = newCommits.count == count
        stashes = newStashes
        status = newStatus
        return changed
    }

    func loadMoreCommits() async throws -> Bool {
        guard hasMoreCommits, head != nil else { return false }
        let more = try await git.log("HEAD", skip: commits.count, count: Repo.pageSize)
        commits += more
        hasMoreCommits = more.count == Repo.pageSize
        return !more.isEmpty
    }

    nonisolated static func loadStatus(_ git: Git) async -> WorktreeStatus {
        guard let data = try? await git.run(["status", "--porcelain=v1", "-z", "--untracked-files=all", "--no-renames", "--ignore-submodules=dirty"]) else { return WorktreeStatus() }
        var s = WorktreeStatus()
        for entry in data.split(separator: 0) where entry.count >= 3 {
            let x = entry[entry.startIndex], y = entry[entry.startIndex + 1]
            s.uncommitted += 1
            let xs = Character(UnicodeScalar(x)), ys = Character(UnicodeScalar(y))
            if xs == "U" || ys == "U" || (xs == "A" && ys == "A") || (xs == "D" && ys == "D") {
                s.conflicted += 1
                s.unstaged += 1
                s.conflictedPaths.insert(String(decoding: entry.dropFirst(3), as: UTF8.self))
                continue
            }
            if xs != " " && xs != "?" { s.staged += 1 }
            if ys != " " { s.unstaged += 1 }
        }
        return s
    }

    /// Interprets a revision expression the way `git diff` would.
    ///
    /// Accepts `A..B`, `A...B`, a single commit, and `staged`, `unstaged` and `uncommitted`.
    func target(for spec: String) async throws -> Target {
        let s = spec.trimmingCharacters(in: .whitespaces)
        switch s.lowercased() {
        case "", "uncommitted", "worktree", "working", "wip": return .uncommitted
        case "staged", "cached", "--staged", "--cached", "index": return .staged
        case "unstaged": return .unstaged
        default: break
        }
        if let r = s.range(of: "...") {
            let a = String(s[..<r.lowerBound]), b = String(s[r.upperBound...])
            let aa = a.isEmpty ? "HEAD" : a, bb = b.isEmpty ? "HEAD" : b
            guard let ao = await git.resolve(aa) else { throw GitError(message: "Unknown revision ‘\(aa)’") }
            guard let bo = await git.resolve(bb) else { throw GitError(message: "Unknown revision ‘\(bb)’") }
            guard let base = await git.mergeBase(ao, bo) else { throw GitError(message: "‘\(aa)’ and ‘\(bb)’ have no common ancestor") }
            return .range(base: base, head: bo, label: "\(aa)...\(bb)")
        }
        if let r = s.range(of: "..") {
            let a = String(s[..<r.lowerBound]), b = String(s[r.upperBound...])
            let aa = a.isEmpty ? "HEAD" : a, bb = b.isEmpty ? "HEAD" : b
            guard let ao = await git.resolve(aa) else { throw GitError(message: "Unknown revision ‘\(aa)’") }
            guard let bo = await git.resolve(bb) else { throw GitError(message: "Unknown revision ‘\(bb)’") }
            return .range(base: ao, head: bo, label: "\(aa)..\(bb)")
        }
        if let stash = stashes.first(where: { $0.ref == s }) { return .stash(stash.oid) }
        guard let oid = await git.resolve(s) else { throw GitError(message: "Unknown revision ‘\(s)’") }
        if let stash = stashes.first(where: { $0.oid == oid }) { return .stash(stash.oid) }
        return .commit(oid)
    }

    func commit(_ oid: String) -> Commit? { commits.first { $0.oid == oid } }
}
