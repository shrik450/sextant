import Foundation

/// Tells the file system changes that may change what a repository's reviews show from those
/// that can't, such as git's own bookkeeping and what Sextant saves.
public struct RepositoryChanges: Sendable {
    public let commonDir: CanonicalPath

    public init(commonDir: CanonicalPath) {
        self.commonDir = commonDir
    }

    /// Whether a change at a path may change a review.
    ///
    /// - Parameter path: A changed path, canonical as FSEvents reports it.
    public func matter(_ path: String) -> Bool {
        if path.hasSuffix(".lock") { return false }
        if let inGit = commonDir.components(of: path) { return matterInGitDirectory(inGit) }
        return !path.contains("/.git/objects/")
    }

    /// Whether a change inside the common git directory may change a review.
    ///
    /// Objects only matter once a ref, the index or HEAD points at them, and logs, LFS's
    /// cache and Sextant's own files never do. Each linked worktree's directory under
    /// `worktrees` has logs of its own.
    private func matterInGitDirectory(_ c: [Substring]) -> Bool {
        guard let first = c.first else { return true }
        switch first {
        case "objects", "logs", "lfs", "sextant": return false
        case "worktrees": return !(c.count > 2 && c[2] == "logs")
        default: return true
        }
    }
}
