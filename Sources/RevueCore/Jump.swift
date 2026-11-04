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

/// A definition in a file, as a file's index entry keeps it.
public struct Definition: Sendable, Equatable, Codable {
    public var name: String
    public var kind: String
    /// The 1-based line of its name.
    public var line: Int
}

/// A definition and the file it's in.
public struct LocatedDefinition: Sendable, Equatable {
    public var name: String
    public var kind: String
    public var path: String
    /// The 1-based line of its name.
    public var line: Int

    public init(name: String, kind: String, path: String, line: Int) {
        self.name = name
        self.kind = kind
        self.path = path
        self.line = line
    }
}

extension Git {
    /// Every file in a snapshot with the ID of its contents, which for files changed in the
    /// worktree is the ID git would give them.
    public func blobs(in snapshot: Snapshot) async throws -> [(path: String, oid: String)] {
        switch snapshot {
        case .commit(let c):
            return parseTree(try await run(["ls-tree", "-r", "-z", c]))
        case .index:
            return parseStaged(try await run(["ls-files", "-s", "-z"]))
        case .worktree:
            var byPath = Dictionary(parseStaged(try await run(["ls-files", "-s", "-z"])).map { ($0.path, $0.oid) }, uniquingKeysWith: { a, _ in a })
            let changed = try await run(["ls-files", "-z", "-m", "-o", "--exclude-standard"])
            let fm = FileManager.default
            var hashable: [String] = []
            for raw in changed.split(separator: 0) {
                let p = String(decoding: raw, as: UTF8.self)
                if fm.fileExists(atPath: root.appendingPathComponent(p).path), !p.contains("\n") {
                    hashable.append(p)
                } else {
                    byPath[p] = nil
                }
            }
            let unique = Array(Set(hashable)).sorted()
            if !unique.isEmpty {
                let oids = try await hashObjects(unique)
                for (p, o) in zip(unique, oids) { byPath[p] = o }
            }
            return byPath.map { ($0.key, $0.value) }.sorted { $0.path < $1.path }
        }
    }
}

/// Parses `git ls-tree -r -z`, keeping files.
func parseTree(_ data: Data) -> [(path: String, oid: String)] {
    data.split(separator: 0).compactMap { record in
        guard let tab = record.firstIndex(of: 0x09) else { return nil }
        let fields = record[..<tab].split(separator: 0x20)
        guard fields.count == 3, fields[1].elementsEqual("blob".utf8) else { return nil }
        return (String(decoding: record[(tab + 1)...], as: UTF8.self), String(decoding: fields[2], as: UTF8.self))
    }
}

/// Parses `git ls-files -s -z`, keeping files at stage 0.
func parseStaged(_ data: Data) -> [(path: String, oid: String)] {
    data.split(separator: 0).compactMap { record in
        guard let tab = record.firstIndex(of: 0x09) else { return nil }
        let fields = record[..<tab].split(separator: 0x20)
        guard fields.count == 3, fields[2].elementsEqual("0".utf8), !fields[0].elementsEqual("160000".utf8) else { return nil }
        return (String(decoding: record[(tab + 1)...], as: UTF8.self), String(decoding: fields[1], as: UTF8.self))
    }
}

/// The definitions in a repository's files, found with each language's tags query.
///
/// Files are kept by the ID of their contents, so each version of a file is parsed once,
/// whatever snapshot it's in, and the index is saved between launches.
public actor DefinitionIndex {
    private let cache: URL?
    private var byBlob: [String: [Definition]] = [:]
    private var loaded = false
    private let runtime: SyntaxRuntime?

    /// The largest file parsed, in bytes.
    static let largestFile = 1 << 20

    /// - Parameters:
    ///   - cache: Where the index is saved, or nil to keep it in memory.
    ///   - runtime: The grammars, or the shared ones.
    public init(cache: URL?, runtime: SyntaxRuntime? = SyntaxRuntime.shared) {
        self.cache = cache
        self.runtime = runtime
    }

    /// Returns every definition in a snapshot's files, parsing the files not seen before.
    ///
    /// - Parameter progress: Told how many files are parsed of how many need it, as they finish.
    public func definitions(in snapshot: Snapshot, git: Git, progress: @escaping @Sendable (Int, Int) -> Void = { _, _ in }) async throws -> [LocatedDefinition] {
        load()
        guard let runtime else { return [] }
        let files = try await git.blobs(in: snapshot).filter { runtime.language(forPath: $0.path)?.hasTags == true }
        let missing = Dictionary(files.filter { byBlob[$0.oid] == nil }.map { ($0.oid, $0.path) }, uniquingKeysWith: { a, _ in a }).map { (oid: $0.key, path: $0.value) }
        if !missing.isEmpty {
            try await parse(missing, in: snapshot, git: git, runtime: runtime, progress: progress)
            save(keeping: Set(files.map(\.oid)))
        }
        return files.flatMap { f in
            (byBlob[f.oid] ?? []).map { LocatedDefinition(name: $0.name, kind: $0.kind, path: f.path, line: $0.line) }
        }
    }

    private func parse(_ missing: [(oid: String, path: String)], in snapshot: Snapshot, git: Git, runtime: SyntaxRuntime,
                       progress: @escaping @Sendable (Int, Int) -> Void) async throws {
        let workers = max(1, ProcessInfo.processInfo.activeProcessorCount - 2)
        try await withThrowingTaskGroup(of: (String, [Definition]).self) { group in
            var next = 0
            func add() {
                guard next < missing.count else { return }
                let (oid, path) = missing[next]
                next += 1
                group.addTask {
                    try Task.checkCancellation()
                    let data = snapshot == .worktree ? git.readWorktreeFile(path, limit: Self.largestFile) : await git.blob(oid: oid)
                    guard let data, data.count <= Self.largestFile, !data.prefix(8000).contains(0),
                          let lang = runtime.language(forPath: path) else { return (oid, []) }
                    let found = outlineDefinitions(lang.symbols(String(decoding: data, as: UTF8.self)).filter(\.isDefinition))
                    return (oid, found.map { Definition(name: $0.name, kind: $0.kind, line: $0.nameLine + 1) })
                }
            }
            for _ in 0..<workers { add() }
            var done = 0
            for try await (oid, defs) in group {
                byBlob[oid] = defs
                done += 1
                if done % 50 == 0 || done == missing.count { progress(done, missing.count) }
                add()
            }
        }
    }

    private func load() {
        guard !loaded else { return }
        loaded = true
        guard let cache, let data = try? Data(contentsOf: cache),
              let saved = try? JSONDecoder().decode([String: [Definition]].self, from: data) else { return }
        byBlob.merge(saved) { a, _ in a }
    }

    /// Saves the index, dropping files from other snapshots once they outnumber this one's,
    /// so the saved index stays near the size of the repository.
    private func save(keeping current: Set<String>) {
        if byBlob.count > current.count * 3 { byBlob = byBlob.filter { current.contains($0.key) } }
        guard let cache else { return }
        try? FileManager.default.createDirectory(at: cache.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(byBlob) { try? data.write(to: cache, options: .atomic) }
    }
}

extension Git {
    /// Returns a blob's contents by object ID, or nil if it can't be read.
    func blob(oid: String) async -> Data? {
        try? await blob(oid)
    }
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
