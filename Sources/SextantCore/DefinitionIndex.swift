import Foundation

/// The definitions in a repository's snapshots, found with each language's tags query.
///
/// Each version of a file is parsed once, through the content analysis, whatever snapshot it's
/// in and whether Go to Anything or a lookup asked for it.
public struct DefinitionIndex: Sendable {
    public let analysis: ContentAnalysis
    private let runtime: SyntaxRuntime?

    /// The largest file parsed, in bytes.
    static let largestFile = 1 << 20

    /// - Parameter runtime: The grammars, or the shared ones.
    public init(analysis: ContentAnalysis, runtime: SyntaxRuntime? = SyntaxRuntime.shared) {
        self.analysis = analysis
        self.runtime = runtime
    }

    /// Returns every definition in a snapshot's files, parsing the versions not seen before.
    ///
    /// - Parameter progress: Told how many files are parsed of how many need it, as they finish.
    public func definitions(in snapshot: Snapshot, git: Git, progress: @escaping @Sendable (Int, Int) -> Void = { _, _ in }) async throws -> [LocatedDefinition] {
        let files = await tagged(try await git.blobs(in: snapshot), git: git)
        let found = try await analysis.definitions(of: files.map(\.source), progress: progress)
        await analysis.prune(keeping: Set(files.map(\.source.key)))
        return files.flatMap { f in (found[f.source.key] ?? []).map { LocatedDefinition($0, path: f.path) } }
    }

    /// Finds a name's uses with `git grep`, and which of them define it, the way GitHub does.
    ///
    /// Every file that uses the name is checked for its definition, parsing only the versions not
    /// seen before.
    ///
    /// - Returns: Every use, and the definitions among them with the text of their lines.
    public func lookUp(_ name: String, in snapshot: Snapshot, git: Git) async throws -> (matches: [GrepMatch], definitions: [GrepMatch]) {
        async let searched = git.grep(name, in: snapshot, word: true, ignoreCase: false, maxPerFile: 200)
        async let listed = snapshot == .worktree ? nil : git.listBlobs(in: snapshot)
        let matches = try await searched
        let paths = Set(matches.map(\.path)).filter { runtime?.hasLanguage(forPath: $0) == true }
        guard !paths.isEmpty else { return (matches, []) }
        let files = if let listing = try await listed {
            await tagged(listing.blobs.filter { paths.contains($0.path) }, git: git)
        } else {
            await worktreeFiles(paths.sorted(), git: git)
        }
        let found = try await analysis.definitions(of: files.map(\.source))
        return (matches, places(of: name, in: files.map { ($0.path, found[$0.source.key] ?? []) }, matches: matches))
    }

    private struct File: Sendable {
        var path: String
        var source: ContentAnalysis.Source
    }

    /// Pairs the files a grammar finds definitions in with how to read them.
    ///
    /// Worktree files git only hashed are read from the worktree, and every other file from git's
    /// objects, so the contents always match the ID.
    @concurrent private func tagged(_ blobs: [SnapshotBlob], git: Git) async -> [File] {
        guard let runtime else { return [] }
        let covered = blobs.filter { runtime.hasLanguage(forPath: $0.path) }
        await runtime.preload(paths: covered.map(\.path))
        return covered.compactMap { b in
            guard let language = runtime.language(forPath: b.path), language.hasTags else { return nil }
            let read: @Sendable () async -> Data? = { [path = b.path, oid = b.oid, inWorktree = b.inWorktree] in
                Self.parseable(inWorktree ? git.readWorktreeFile(path, limit: Self.largestFile) : await git.blob(oid: oid))
            }
            return File(path: b.path, source: ContentAnalysis.Source(key: ContentKey(oid: b.oid, grammar: language.version), language: language, read: read))
        }
    }

    /// Reads regular worktree files and names each by its contents.
    ///
    /// The files a search just read are cheaper to read and hash again than to ask git which
    /// files changed, which looks at every file in the worktree. The name is the ID git gives
    /// the contents unless its filters change them on checkout.
    @concurrent private func worktreeFiles(_ paths: [String], git: Git) async -> [File] {
        guard let runtime else { return [] }
        await runtime.preload(paths: paths)
        return await withTaskGroup(of: File?.self) { group in
            for path in paths {
                group.addTask {
                    let url = git.root.appendingPathComponent(path)
                    guard let language = runtime.language(forPath: path), language.hasTags,
                          (try? FileManager.default.attributesOfItem(atPath: url.path))?[.type] as? FileAttributeType == .typeRegular,
                          let data = Self.parseable(git.readWorktreeFile(path, limit: Self.largestFile)) else { return nil }
                    return File(path: path, source: ContentAnalysis.Source(key: ContentKey(oid: blobID(of: data), grammar: language.version), language: language, read: { data }))
                }
            }
            var files: [File] = []
            for await f in group { if let f { files.append(f) } }
            return files.sorted { $0.path < $1.path }
        }
    }

    /// Returns contents worth parsing: not too large, and not binary.
    private static func parseable(_ data: Data?) -> Data? {
        guard let data, data.count <= largestFile, !data.prefix(8000).contains(0) else { return nil }
        return data
    }
}

/// Returns where a name is defined, with the text of each line from a search for the name.
///
/// - Parameters:
///   - files: Each file's path and definitions.
///   - matches: The search's matches, which hold the lines that define the name.
func places(of name: String, in files: [(path: String, definitions: [Definition])], matches: [GrepMatch]) -> [GrepMatch] {
    let text = Dictionary(matches.map { ("\($0.line):\($0.path)", $0.text) }, uniquingKeysWith: { a, _ in a })
    var seen = Set<String>()
    return files.flatMap { f in
        f.definitions.filter { $0.name == name }.compactMap { d -> GrepMatch? in
            let at = "\(d.line):\(f.path)"
            guard seen.insert(at).inserted else { return nil }
            return GrepMatch(path: f.path, line: d.line, column: 1, text: text[at] ?? name)
        }
    }
}
