import Foundation

/// A row of the file tree: a folder, a file, or a placeholder for a folder's hidden unchanged items.
public struct FileNode: Sendable, Equatable {
    public enum Kind: Sendable, Equatable {
        case folder
        case file
        /// Stands for this many unchanged items in the folder at `path`.
        case unchanged(Int)
    }

    /// What the row shows: a name, or a chain of folders like `src/review`.
    public var name: String
    /// The full path of the folder or file; for `unchanged`, the folder whose items it stands for.
    public var path: String
    public var kind: Kind
    public var children: [FileNode]
    /// Changed files at or under this node.
    public var changed: Int
    /// Reviewed files among `changed`.
    public var reviewed: Int
}

/// Builds the tree of a snapshot's files, showing changed files and folding the rest away.
///
/// Like unchanged lines around a change, unchanged files are folded: each folder shown ends with
/// one `unchanged` row for the items it hides, the root's having an empty path, and a folder that
/// only leads to changes deeper down merges with them into one row, such as `crates/core/src`.
///
/// - Parameters:
///   - paths: Every file in the snapshot, plus any deleted files under review.
///   - changed: The paths of changed files.
///   - reviewed: The paths of changed files marked as reviewed.
///   - showUnchanged: Whether to show every file instead of folding unchanged ones.
///   - revealed: Folders whose unchanged items are shown in place.
public func fileTree(paths: [String], changed: Set<String>, reviewed: Set<String>, showUnchanged: Bool, revealed: Set<String>) -> [FileNode] {
    let root = Folder()
    for p in paths { root.insert(p.split(separator: "/").map(String.init)[...]) }
    for p in changed { root.insert(p.split(separator: "/").map(String.init)[...]) }
    root.count(prefix: "", changed: changed, reviewed: reviewed)
    return root.nodes(prefix: "", showAll: showUnchanged, revealed: revealed, changed: changed, reviewed: reviewed)
}

private final class Folder {
    var folders: [String: Folder] = [:]
    var files: Set<String> = []
    var changed = 0
    var reviewed = 0

    func insert(_ comps: ArraySlice<String>) {
        guard let first = comps.first else { return }
        if comps.count == 1 {
            files.insert(first)
        } else {
            let f = folders[first] ?? Folder()
            folders[first] = f
            f.insert(comps.dropFirst())
        }
    }

    func count(prefix: String, changed: Set<String>, reviewed: Set<String>) {
        var c = 0, r = 0
        for name in files {
            let p = prefix + name
            if changed.contains(p) { c += 1; if reviewed.contains(p) { r += 1 } }
        }
        for (name, f) in folders {
            f.count(prefix: prefix + name + "/", changed: changed, reviewed: reviewed)
            c += f.changed
            r += f.reviewed
        }
        self.changed = c
        self.reviewed = r
    }

    private static func sorted(_ names: some Sequence<String>) -> [String] {
        names.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    func nodes(prefix: String, showAll: Bool, revealed: Set<String>, changed: Set<String>, reviewed: Set<String>) -> [FileNode] {
        let here = String(prefix.dropLast())
        let showsEverything = showAll || revealed.contains(here) || (self.changed == 0 && !prefix.isEmpty)
        var out: [FileNode] = []
        for name in Folder.sorted(folders.keys) {
            let f = folders[name]!
            guard showsEverything || f.changed > 0 else { continue }
            out.append(f.node(name: name, path: prefix + name, showAll: showAll, revealed: revealed, changed: changed, reviewed: reviewed))
        }
        for name in Folder.sorted(files) {
            let p = prefix + name
            let isChanged = changed.contains(p)
            guard showsEverything || isChanged else { continue }
            out.append(FileNode(name: name, path: p, kind: .file, children: [], changed: isChanged ? 1 : 0, reviewed: isChanged && reviewed.contains(p) ? 1 : 0))
        }
        if !showsEverything {
            let hidden = folders.values.filter { $0.changed == 0 }.count + files.filter { !changed.contains(prefix + $0) }.count
            if hidden > 0 { out.append(FileNode(name: "", path: here, kind: .unchanged(hidden), children: [], changed: 0, reviewed: 0)) }
        }
        return out
    }

    func node(name: String, path: String, showAll: Bool, revealed: Set<String>, changed: Set<String>, reviewed: Set<String>) -> FileNode {
        if let (childName, child) = mergedChild(path: path, showAll: showAll, changed: changed) {
            var n = child.node(name: childName, path: path + "/" + childName, showAll: showAll, revealed: revealed, changed: changed, reviewed: reviewed)
            n.name = name + "/" + n.name
            return n
        }
        return FileNode(name: name, path: path, kind: .folder,
                        children: nodes(prefix: path + "/", showAll: showAll, revealed: revealed, changed: changed, reviewed: reviewed),
                        changed: self.changed, reviewed: self.reviewed)
    }

    /// The one subfolder this folder merges with into a single row, if any.
    ///
    /// When everything is shown, a folder merges with an only child folder. When unchanged items
    /// are folded, a folder that holds no changed files merges with its one subfolder holding changes,
    /// hiding its unchanged items until everything is shown.
    private func mergedChild(path: String, showAll: Bool, changed: Set<String>) -> (String, Folder)? {
        if showAll || self.changed == 0 {
            guard files.isEmpty, folders.count == 1, let only = folders.first else { return nil }
            return (only.key, only.value)
        }
        guard !files.contains(where: { changed.contains(path + "/" + $0) }) else { return nil }
        let leading = folders.filter { $0.value.changed > 0 }
        guard leading.count == 1, let only = leading.first else { return nil }
        return (only.key, only.value)
    }
}

/// A run of consecutive changed lines in a file.
public struct ChangeRun: Sendable, Equatable {
    /// The indices of the run's lines in the file's lines.
    public var lines: Range<Int>
    public var additions: Int
    public var deletions: Int
    /// The zero-based new-side line where the run sits: its first added line, or the line after
    /// the removal.
    public var newLine: Int
}

/// Finds the runs of changed lines in a file's lines.
public func changeRuns(_ lines: [DiffLine]) -> [ChangeRun] {
    var out: [ChangeRun] = []
    var i = 0
    while i < lines.count {
        guard lines[i].kind != .context else { i += 1; continue }
        let start = i
        var adds = 0, dels = 0
        while i < lines.count, lines[i].kind != .context {
            if lines[i].kind == .added { adds += 1 } else { dels += 1 }
            i += 1
        }
        let firstAdded = lines[start..<i].first { $0.kind == .added }
        let newLine = firstAdded.map { $0.newNo - 1 } ?? (start > 0 ? lines[start - 1].newNo : 0)
        out.append(ChangeRun(lines: start..<i, additions: adds, deletions: dels, newLine: max(0, newLine)))
    }
    return out
}
