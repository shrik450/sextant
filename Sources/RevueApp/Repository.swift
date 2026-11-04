import Foundation
import RevueCore

/// A repository's checkouts and refs: what there is to review.
///
/// One repository backs one window, whichever of its worktrees it was opened from. Ref reads run
/// in the common git directory, so they keep working when a linked worktree goes away.
@MainActor
final class Repository {
    let git: Git
    let commonDir: URL
    let reviews: ReviewStore
    let notes: NotesStore

    /// The main checkout first, then linked worktrees.
    private(set) var worktrees: [Worktree] = []
    /// Local and remote-tracking branches, most recent first, compared with `defaultBase`.
    private(set) var branches: [Branch] = []
    private(set) var stashes: [Stash] = []
    /// What branches are compared with unless the user picks something else, like `origin/main`.
    private(set) var defaultBase: String?
    /// Open pull requests, or nil when `gh` isn't available or hasn't answered yet.
    private(set) var pullRequests: [PullRequest]?
    /// The number of uncommitted files in each worktree, by root path.
    private(set) var uncommitted: [String: Int] = [:]
    /// Paths with merge conflicts in each worktree, by root path.
    private(set) var conflicts: [String: Set<String>] = [:]

    init(commonDir: URL, gitPath: String) {
        self.commonDir = commonDir
        git = Git(root: commonDir, executable: gitPath)
        reviews = ReviewStore.shared(for: commonDir)
        notes = NotesStore.shared(for: commonDir)
    }

    /// The repository's name, from its main checkout.
    var name: String {
        if let main = worktrees.first { return main.root.lastPathComponent }
        let parent = commonDir.deletingLastPathComponent()
        return commonDir.lastPathComponent == ".git" ? parent.lastPathComponent : commonDir.deletingPathExtension().lastPathComponent
    }

    var resolver: Resolver { Resolver(git: git) }

    func worktree(at root: URL) -> Worktree? {
        let std = root.standardizedFileURL.path
        return worktrees.first { $0.root.standardizedFileURL.path == std }
    }

    /// The checkout where a branch is checked out, if any.
    func worktree(onBranch name: String) -> Worktree? { worktrees.first { $0.branch == name } }

    /// The checkout to open files in for a subject: its own, the one on its branch, or the main one.
    func checkout(for subject: Subject, pullRequest: PullRequest?) -> URL? {
        switch subject {
        case .worktree(let root): return root
        case .branch(let b): return (worktree(onBranch: b) ?? worktrees.first)?.root
        case .pullRequest: return (pullRequest.flatMap { worktree(onBranch: $0.headRefName) } ?? worktrees.first)?.root
        default: return worktrees.first?.root
        }
    }

    /// Reloads worktrees, branches, stashes and each worktree's status.
    ///
    /// - Returns: Whether anything changed.
    @discardableResult
    func refresh() async -> Bool {
        let refs = await refreshRefs()
        let status = await refreshStatus()
        return refs || status
    }

    /// The default branch, worktrees, branches and stashes, which opening a review needs.
    struct Refs: Sendable {
        var base: String?
        var worktrees: [Worktree]
        var branches: [Branch]
        var stashes: [Stash]
    }

    /// Reads a repository's refs without touching any state, so it can start before the window
    /// it's for exists.
    nonisolated static func readRefs(_ git: Git) async -> Refs {
        let base = await git.defaultBranch()
        async let worktrees = git.worktrees()
        async let branches = git.branches(comparedWith: base)
        async let stashes = git.stashes()
        return await Refs(base: base, worktrees: worktrees, branches: branches, stashes: stashes)
    }

    /// Reloads the refs.
    ///
    /// - Parameter known: Refs already read, to use instead of reading them again.
    /// - Returns: Whether anything changed.
    @discardableResult
    func refreshRefs(_ known: Refs? = nil) async -> Bool {
        let refs = if let known { known } else { await Repository.readRefs(git) }
        let changed = refs.base != defaultBase || refs.worktrees != worktrees || refs.branches != branches || refs.stashes != stashes
        defaultBase = refs.base
        worktrees = refs.worktrees
        branches = refs.branches
        stashes = refs.stashes
        return changed
    }

    /// Reloads what's uncommitted and conflicted in each worktree, which only counts and marks
    /// need, so a review can open without waiting for it.
    ///
    /// - Returns: Whether anything changed.
    @discardableResult
    func refreshStatus() async -> Bool {
        let git = self.git
        let statuses = await withTaskGroup(of: (String, WorktreeStatus).self) { group in
            for w in worktrees {
                group.addTask { (w.root.path, await Repository.status(of: Git(root: w.root, executable: git.executable))) }
            }
            var out: [String: WorktreeStatus] = [:]
            for await (k, v) in group { out[k] = v }
            return out
        }
        let newUncommitted = statuses.mapValues(\.count)
        let newConflicts = statuses.mapValues(\.conflicts)
        let changed = newUncommitted != uncommitted || newConflicts != conflicts
        uncommitted = newUncommitted
        conflicts = newConflicts
        return changed
    }

    /// Asks `gh` for the open pull requests, leaving `pullRequests` nil if it can't answer.
    func loadPullRequests() async {
        guard let gh = Repository.ghPath, let root = worktrees.first?.root else { return }
        pullRequests = try? await listPullRequests(in: root, gh: gh, path: userPath())
    }

    private static let ghPath: String? = userPath().split(separator: ":").map { "\($0)/gh" }.first { FileManager.default.isExecutableFile(atPath: $0) }

    private struct WorktreeStatus: Sendable {
        var count = 0
        var conflicts: Set<String> = []
    }

    private nonisolated static func status(of git: Git) async -> WorktreeStatus {
        guard let data = try? await git.run(["status", "--porcelain=v1", "-z", "--untracked-files=all", "--no-renames", "--ignore-submodules=dirty"], priority: .utility) else { return WorktreeStatus() }
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

    /// The base a subject is compared with: the one last picked for it, else the pull request's
    /// own base or the default.
    func base(for subject: Subject) -> String? { Repository.base(for: subject, usual: defaultBase, commonDir: commonDir) }

    nonisolated static func base(for subject: Subject, usual: String?, commonDir: URL) -> String? {
        guard subject.hasBase else { return nil }
        if let saved = savedBases[baseKey(subject, commonDir: commonDir)] { return saved }
        if case .pullRequest = subject { return nil }
        return usual
    }

    /// Remembers the base picked for a subject, forgetting it when it's the one it would get anyway.
    func remember(base: String, for subject: Subject, usual: String?) {
        var saved = Repository.savedBases
        saved[Repository.baseKey(subject, commonDir: commonDir)] = base == usual ? nil : base
        UserDefaults.standard.set(saved, forKey: "bases")
    }

    nonisolated private static var savedBases: [String: String] { UserDefaults.standard.dictionary(forKey: "bases") as? [String: String] ?? [:] }

    nonisolated private static func baseKey(_ s: Subject, commonDir: URL) -> String { commonDir.standardizedFileURL.path + "|" + s.key }

    /// Reads a typed revision expression as something to review.
    func review(for spec: RevisionSpec, in worktree: URL?) async throws -> Review {
        let refs = Refs(base: defaultBase, worktrees: worktrees, branches: branches, stashes: stashes)
        return try await Repository.review(for: spec, in: worktree, refs: refs, git: git, commonDir: commonDir)
    }

    nonisolated static func review(for spec: RevisionSpec, in worktree: URL?, refs: Refs, git: Git, commonDir: URL) async throws -> Review {
        let here = worktree ?? refs.worktrees.first?.root
        func base(_ s: Subject) -> String? { Repository.base(for: s, usual: refs.base, commonDir: commonDir) }
        switch spec {
        case .uncommitted, .staged, .unstaged:
            guard let here else { throw GitError(message: "This repository has no checkout") }
            let subject = Subject.worktree(here)
            let scope: Scope = spec == .uncommitted ? .uncommitted : spec == .staged ? .staged : .unstaged
            return Review(subject: subject, base: base(subject), scope: scope)
        case .pullRequest(let n):
            return Review(subject: .pullRequest(n))
        case .comparison(let from, let to, let since):
            return Review(subject: .comparison(from: from, to: to, sinceAncestor: since))
        case .revision(let r):
            if let stash = refs.stashes.first(where: { $0.ref == r }) { return Review(subject: .stash(stash.oid)) }
            if let b = refs.branches.first(where: { $0.name == r }) {
                let subject = Subject.branch(b.name)
                return Review(subject: subject, base: base(subject))
            }
            guard let oid = await git.resolve(r) else { throw GitError(message: "Unknown revision ‘\(r)’") }
            if let stash = refs.stashes.first(where: { $0.oid == oid }) { return Review(subject: .stash(stash.oid)) }
            return Review(subject: .commit(oid))
        }
    }

    /// A review read before its window exists, so git runs while AppKit makes the window instead
    /// of after it.
    struct Opening: Sendable {
        var refs: Refs
        /// The review, resolved and diffed, unless it couldn't be without the window, like a pull
        /// request, which needs the GitHub CLI.
        var loaded: Loaded?
    }

    struct Loaded: Sendable {
        var review: Review
        var resolved: ResolvedReview
        var diffs: [FileDiff]
        /// The first change as a whole file, since it shows first.
        var firstWhole: [DiffLine]?
    }

    /// Reads what opening a repository shows: the review a revision expression names, or all the
    /// work in the checkout it's opened from.
    nonisolated static func open(_ spec: String?, in home: URL?, git: Git, commonDir: URL) async -> Opening {
        let refs = await readRefs(git)
        let review: Review?
        if let spec, !spec.isEmpty, let parsed = parseRevisionSpec(spec) {
            review = try? await Repository.review(for: parsed, in: home, refs: refs, git: git, commonDir: commonDir)
        } else {
            review = home.map { Review(subject: .worktree($0), base: base(for: .worktree($0), usual: refs.base, commonDir: commonDir)) }
        }
        guard let review else { return Opening(refs: refs) }
        if case .pullRequest = review.subject { return Opening(refs: refs) }
        guard let resolved = try? await Resolver(git: git).resolve(review, worktrees: refs.worktrees, pullRequests: []),
              let diffs = try? await resolved.git.diff(resolved.target) else { return Opening(refs: refs) }
        var firstWhole: [DiffLine]?
        if let first = diffs.first, !first.isBinary, let old = try? await resolved.git.oldLines(of: first) {
            firstWhole = wholeFile(first.hunks, oldLines: old)
        }
        return Opening(refs: refs, loaded: Loaded(review: review, resolved: resolved, diffs: diffs, firstWhole: firstWhole))
    }
}
