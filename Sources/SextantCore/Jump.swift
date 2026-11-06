import Foundation

/// Returns how well a query matches a candidate, or nil if it doesn't, ignoring case.
///
/// A query that is the name ranks first, then one the name starts with, one inside the name,
/// one inside the rest of the candidate, and last one whose letters appear in order, where
/// letters that start a word count more.
///
/// - Parameters:
///   - query: What was typed.
///   - candidate: The whole thing matched, such as a path.
///   - name: The part that names it, such as the file name.
public func fuzzyScore(_ query: String, candidate: String, name: String) -> Int? {
    let q = query.lowercased()
    guard !q.isEmpty else { return nil }
    let n = name.lowercased()
    let score: Int
    if n == q { score = 1000 }
    else if n.hasPrefix(q) { score = 800 }
    else if n.contains(q) { score = 600 }
    else if candidate.lowercased().contains(q) { score = 400 }
    else {
        let wanted = Array(q)
        var qi = 0, s = 0
        var prev: Character = "/"
        for c in candidate where qi < wanted.count {
            if Character(c.lowercased()) == wanted[qi] {
                let startsWord = "/_-. :".contains(prev) || (c.isUppercase && prev.isLowercase)
                s += startsWord ? 10 : 1
                qi += 1
            }
            prev = c
        }
        guard qi == wanted.count else { return nil }
        score = min(s, 399)
    }
    return score * 1000 - min(999, candidate.count)
}

/// Fuzzy-matches paths and ranks them like Open Quickly, best first.
public func rankFuzzy(_ query: String, _ paths: [String]) -> [String] {
    paths.compactMap { p in fuzzyScore(query, candidate: p, name: (p as NSString).lastPathComponent).map { ($0, p) } }
        .sorted { $0.0 > $1.0 }
        .map(\.1)
}

/// A definition in a file, as a file's analysis keeps it.
public struct Definition: Sendable, Equatable {
    public var name: String
    public var kind: String
    /// The 1-based line of its name.
    public var line: Int
    /// Whether it belongs in the file's outline, rather than inside a function or method, like a
    /// local variable.
    public var inOutline: Bool

    public init(name: String, kind: String, line: Int, inOutline: Bool) {
        self.name = name
        self.kind = kind
        self.line = line
        self.inOutline = inOutline
    }
}

/// Coded as `[name, kind, line, inOutline]`, since a saved index holds a great many.
extension Definition: Codable {
    public init(from decoder: Decoder) throws {
        var c = try decoder.unkeyedContainer()
        name = try c.decode(String.self)
        kind = try c.decode(String.self)
        line = try c.decode(Int.self)
        inOutline = try c.decode(Bool.self)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.unkeyedContainer()
        try c.encode(name)
        try c.encode(kind)
        try c.encode(line)
        try c.encode(inOutline)
    }
}

/// Returns the definitions among what a tags query found, as a file's analysis keeps them.
///
/// - Parameter symbols: Definitions and references in document order.
public func indexedDefinitions(_ symbols: [Symbol]) -> [Definition] {
    let defs = symbols.filter(\.isDefinition)
    return zip(defs, inOutline(defs)).map { d, outlined in
        Definition(name: d.name, kind: d.kind, line: d.nameLine + 1, inOutline: outlined)
    }
}

/// A definition and the file it's in.
public struct LocatedDefinition: Sendable, Equatable {
    public var name: String
    public var kind: String
    public var path: String
    /// The 1-based line of its name.
    public var line: Int
    /// Whether it belongs in the file's outline, rather than inside a function or method.
    public var inOutline: Bool

    public init(name: String, kind: String, path: String, line: Int, inOutline: Bool) {
        self.name = name
        self.kind = kind
        self.path = path
        self.line = line
        self.inOutline = inOutline
    }

    init(_ d: Definition, path: String) {
        self.init(name: d.name, kind: d.kind, path: path, line: d.line, inOutline: d.inOutline)
    }
}

/// A regular file in a snapshot, with the ID of its contents.
struct SnapshotBlob: Sendable, Equatable {
    var path: String
    var oid: String
    /// Whether its contents are only in the worktree, where git hashed them without storing them.
    var inWorktree: Bool
}

/// A snapshot's regular files: those git has IDs for, and worktree files that need hashing.
struct SnapshotListing: Sendable {
    var blobs: [SnapshotBlob]
    /// Files changed in the worktree, whose IDs git hasn't computed.
    var unhashed: [String]
}

extension Git {
    /// Every regular file in a snapshot with the ID of its contents, which for files changed in
    /// the worktree is the ID git would give them.
    ///
    /// Symbolic links and submodules are left out, since their contents aren't code.
    func blobs(in snapshot: Snapshot) async throws -> [SnapshotBlob] {
        let listing = try await listBlobs(in: snapshot)
        return (listing.blobs + (try await hashed(listing.unhashed))).sorted { $0.path < $1.path }
    }

    /// Lists a snapshot's regular files without hashing those changed in the worktree.
    func listBlobs(in snapshot: Snapshot) async throws -> SnapshotListing {
        switch snapshot {
        case .commit(let c):
            return SnapshotListing(blobs: parseTree(try await run(["ls-tree", "-r", "-z", c])).map { SnapshotBlob(path: $0.path, oid: $0.oid, inWorktree: false) }, unhashed: [])
        case .index:
            return SnapshotListing(blobs: parseStaged(try await run(["ls-files", "-s", "-z"])).map { SnapshotBlob(path: $0.path, oid: $0.oid, inWorktree: false) }, unhashed: [])
        case .worktree:
            async let staged = run(["ls-files", "-s", "-z"])
            async let changed = run(["ls-files", "-z", "-m", "-o", "--exclude-standard"])
            var byPath = Dictionary(parseStaged(try await staged).map { ($0.path, $0.oid) }, uniquingKeysWith: { a, _ in a })
            var unhashed = Set<String>()
            for raw in try await changed.split(separator: 0) {
                let p = String(decoding: raw, as: UTF8.self)
                byPath[p] = nil
                let type = (try? FileManager.default.attributesOfItem(atPath: root.appendingPathComponent(p).path))?[.type] as? FileAttributeType
                if type == .typeRegular { unhashed.insert(p) }
            }
            return SnapshotListing(blobs: byPath.map { SnapshotBlob(path: $0.key, oid: $0.value, inWorktree: false) }, unhashed: unhashed.sorted())
        }
    }

    /// Hashes worktree files the way git would, without storing them.
    func hashed(_ paths: [String]) async throws -> [SnapshotBlob] {
        guard !paths.isEmpty else { return [] }
        return zip(paths, try await hashObjects(paths)).compactMap { path, oid in oid.map { SnapshotBlob(path: path, oid: $0, inWorktree: true) } }
    }

    /// Returns a blob's contents by object ID, or nil if it can't be read.
    func blob(oid: String) async -> Data? {
        try? await blob(oid)
    }
}

/// Parses `git ls-tree -r -z`, keeping regular files.
func parseTree(_ data: Data) -> [(path: String, oid: String)] {
    data.split(separator: 0).compactMap { record in
        guard let tab = record.firstIndex(of: 0x09) else { return nil }
        let fields = record[..<tab].split(separator: 0x20)
        guard fields.count == 3, fields[1].elementsEqual("blob".utf8), isRegularMode(fields[0]) else { return nil }
        return (String(decoding: record[(tab + 1)...], as: UTF8.self), String(decoding: fields[2], as: UTF8.self))
    }
}

/// Parses `git ls-files -s -z`, keeping regular files at stage 0.
func parseStaged(_ data: Data) -> [(path: String, oid: String)] {
    data.split(separator: 0).compactMap { record in
        guard let tab = record.firstIndex(of: 0x09) else { return nil }
        let fields = record[..<tab].split(separator: 0x20)
        guard fields.count == 3, fields[2].elementsEqual("0".utf8), isRegularMode(fields[0]) else { return nil }
        return (String(decoding: record[(tab + 1)...], as: UTF8.self), String(decoding: fields[1], as: UTF8.self))
    }
}

private func isRegularMode(_ mode: Data.SubSequence) -> Bool {
    mode.elementsEqual("100644".utf8) || mode.elementsEqual("100755".utf8)
}

/// What a query typed to jump means, by its first character.
public enum JumpQuery: Equatable, Sendable {
    /// Files and definitions anywhere.
    case anything(String)
    /// Commands from the menus, after `>`.
    case commands(String)
    /// A line of the file being read, after `:`.
    case line(Int?)
    /// Definitions in the file being read, after `@`.
    case fileDefinitions(String)
    /// Definitions anywhere, after `#`.
    case definitions(String)
}

/// Reads a query typed to jump.
public func parseJumpQuery(_ text: String) -> JumpQuery {
    let trimmed = text.trimmingCharacters(in: .whitespaces)
    guard let first = trimmed.first else { return .anything("") }
    let rest = String(trimmed.dropFirst()).trimmingCharacters(in: .whitespaces)
    switch first {
    case ">": return .commands(rest)
    case ":": return .line(Int(rest))
    case "@": return .fileDefinitions(rest)
    case "#": return .definitions(rest)
    default: return .anything(trimmed)
    }
}

/// A file or definition that matches a jump query.
public enum JumpMatch: Equatable, Sendable {
    case file(String)
    case definition(LocatedDefinition)
}

/// Ranks files and definitions against a query, best first.
///
/// Files and definitions rank together by how well their names match, and among equal
/// matches, a file the change touched comes first.
///
/// - Parameters:
///   - changed: The files the change touched.
///   - limit: The most matches to return.
public func rankJump(_ query: String, files: [String], changed: Set<String>, definitions: [LocatedDefinition], limit: Int) -> [JumpMatch] {
    var scored: [(Int, JumpMatch)] = []
    for p in files {
        guard let s = fuzzyScore(query, candidate: p, name: (p as NSString).lastPathComponent) else { continue }
        scored.append((s + (changed.contains(p) ? 500 : 0), .file(p)))
    }
    for d in definitions {
        guard let s = fuzzyScore(query, candidate: d.name, name: d.name) else { continue }
        scored.append((s + (changed.contains(d.path) ? 500 : 0), .definition(d)))
    }
    scored.sort { $0.0 > $1.0 }
    return scored.prefix(limit).map(\.1)
}
