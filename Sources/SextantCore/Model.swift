import Foundation

public let zeroOid = String(repeating: "0", count: 40)
public let emptyTreeOid = "4b825dc642cb6eb9a060e54bf8d69288fbee4904"

/// One entry of `git diff --raw` / `git log --raw`.
public struct RawChange: Sendable, Hashable {
    public var status: Character
    public var score: Int?
    public var oldMode: String
    public var newMode: String
    public var oldOid: String
    public var newOid: String
    public var oldPath: String
    public var path: String

    public init(status: Character, score: Int? = nil, oldMode: String, newMode: String, oldOid: String, newOid: String, oldPath: String, path: String) {
        self.status = status
        self.score = score
        self.oldMode = oldMode
        self.newMode = newMode
        self.oldOid = oldOid
        self.newOid = newOid
        self.oldPath = oldPath
        self.path = path
    }

    /// The identity of this change for review purposes.
    ///
    /// The same transition (content, mode and path on both sides) is the same change, wherever
    /// it shows up (working tree, commit, range).
    public var reviewKey: String { "\(oldOid) \(oldMode) \(newOid) \(newMode)\t\(oldPath)\t\(path)" }

    /// The identity of the file this change starts from, which its runs of changes are read in
    /// (see `ReadingState`).
    ///
    /// It leaves out the new side, so it stays the same however the file changes from there.
    public var readingKey: String { "\(oldOid) \(oldMode)\t\(oldPath)\t\(path)" }

    public var isRename: Bool { status == "R" }
    public var isAdded: Bool { status == "A" || status == "?" }
    public var isDeleted: Bool { status == "D" }
    public var isUntracked: Bool { status == "?" }
}

public struct Commit: Sendable, Hashable, Identifiable {
    public var oid: String
    public var parents: [String]
    public var author: String
    public var email: String
    public var date: Date
    public var subject: String
    public var refs: [String]
    public var changes: [RawChange]

    public var id: String { oid }
    public var shortOid: String { String(oid.prefix(7)) }
    public var isMerge: Bool { parents.count > 1 }
}

public struct CommitDetail: Sendable, Hashable {
    public var oid: String
    public var parents: [String]
    public var author: String
    public var email: String
    public var authorDate: Date
    public var committer: String
    public var committerDate: Date
    public var message: String

    /// The message's first line, whichever line ending it has.
    public var summary: String { String(message.prefix { !$0.isNewline }) }
    /// The message after its first line, without the blank lines around it.
    public var body: String { message.drop { !$0.isNewline }.trimmingCharacters(in: .whitespacesAndNewlines) }
}

public struct Stash: Sendable, Hashable, Identifiable {
    public var oid: String
    public var parents: [String]
    public var ref: String
    public var date: Date
    public var subject: String
    public var id: String { oid }
}

public enum LineKind: UInt8, Sendable {
    case context, added, deleted
}

public struct DiffLine: Sendable, Hashable {
    public var kind: LineKind
    public var oldNo: Int
    public var newNo: Int
    public var text: String
    /// Whether the line is the last of its file, with no newline after it.
    public var noNewline: Bool = false
    /// Whether the line ended in CR LF, before `text` left the CR out.
    ///
    /// Only a patch's lines say; lines filled in from a blob never do.
    public var carriageReturn = false

    public init(kind: LineKind, oldNo: Int, newNo: Int, text: String, noNewline: Bool = false) {
        self.kind = kind
        self.oldNo = oldNo
        self.newNo = newNo
        self.text = text
        self.noNewline = noNewline
    }
}

public struct Hunk: Sendable, Hashable {
    public var oldStart: Int
    public var oldCount: Int
    public var newStart: Int
    public var newCount: Int
    public var section: String
    public var lines: [DiffLine]

    public init(oldStart: Int, oldCount: Int, newStart: Int, newCount: Int, section: String, lines: [DiffLine]) {
        self.oldStart = oldStart
        self.oldCount = oldCount
        self.newStart = newStart
        self.newCount = newCount
        self.section = section
        self.lines = lines
    }

    /// First old-side line number after this hunk.
    public var oldEnd: Int { oldStart + oldCount }
    public var newEnd: Int { newStart + newCount }
}

public struct FileDiff: Sendable, Hashable, Identifiable {
    public var change: RawChange
    public var hunks: [Hunk]
    public var isBinary: Bool
    public var notes: [String]
    public var additions: Int
    public var deletions: Int

    public var id: String { change.path }
    public var path: String { change.path }

    public init(change: RawChange, hunks: [Hunk] = [], isBinary: Bool = false, notes: [String] = []) {
        self.change = change
        self.hunks = hunks
        self.isBinary = isBinary
        self.notes = notes
        var a = 0, d = 0
        for h in hunks {
            for l in h.lines {
                if l.kind == .added { a += 1 } else if l.kind == .deleted { d += 1 }
            }
        }
        additions = a
        deletions = d
    }

    public var lineCount: Int { hunks.reduce(0) { $0 + $1.lines.count } }

    /// Whether the hunks already hold the whole file, so there are no unchanged lines around
    /// them to fill in.
    ///
    /// An added or deleted file's one hunk is the whole file. A file without hunks is whole only
    /// when there's nothing to read: an empty file added or deleted, or a submodule, whose IDs
    /// name commits. A rename or a mode change without hunks keeps all its lines, unchanged.
    public var hunksAreWholeFile: Bool {
        if hunks.isEmpty {
            return change.isAdded || change.isDeleted || change.oldOid == zeroOid || change.oldMode == gitlinkMode || change.newMode == gitlinkMode
        }
        return hunks.count == 1 && (change.isAdded || change.isDeleted)
    }
}

/// The two sides of a diff to load.
public enum Target: Sendable, Hashable {
    /// The working files, including untracked ones, against a commit, or against HEAD when
    /// `since` is nil.
    case worktree(since: String?)
    case staged
    /// The working files against the index, with an unmerged file against our side of the merge.
    case unstaged
    /// A commit against its first parent.
    case commit(String)
    /// The tree diff `base..head`.
    case range(base: String, head: String)
    case stash(String)

    public var includesWorktree: Bool {
        switch self {
        case .worktree, .unstaged: true
        default: false
        }
    }

    public var includesIndex: Bool {
        switch self {
        case .worktree, .unstaged, .staged: true
        default: false
        }
    }

    /// The tree the target's changes lead to, which is what gets reviewed and explored.
    public var snapshot: Snapshot {
        switch self {
        case .worktree, .unstaged: .worktree
        case .staged: .index
        case .commit(let c): .commit(c)
        case .range(_, let head): .commit(head)
        case .stash(let s): .commit(s)
        }
    }
}

/// A complete tree of files: the working tree, the index, or a commit.
public enum Snapshot: Sendable, Hashable {
    case worktree
    case index
    case commit(String)
}

/// One line of `git grep` output.
public struct GrepMatch: Sendable, Hashable {
    public var path: String
    public var line: Int
    /// The 1-based byte column of the match, as git reports it.
    public var column: Int
    public var text: String

    public init(path: String, line: Int, column: Int, text: String) {
        self.path = path
        self.line = line
        self.column = column
        self.text = text
    }
}

/// Who last touched each line of a file.
public struct Blame: Sendable {
    public struct Commit: Sendable, Hashable {
        public var oid: String
        public var author: String
        public var date: Date
        public var summary: String
        /// Whether this entry stands for lines not yet committed (worktree or index edits).
        public var isUncommitted: Bool { oid == zeroOid }
    }

    /// The commit oid for each line, in file order.
    public var lines: [String]
    public var commits: [String: Commit]

    public func commit(forLine i: Int) -> Commit? {
        i < lines.count ? commits[lines[i]] : nil
    }
}
