import CryptoKit
import Foundation

/// Names a version of a file's contents as parsed with one build of a grammar.
public struct ContentKey: Hashable, Sendable {
    /// The blob ID of the contents.
    public var oid: String
    /// The grammar's `SyntaxLanguage.version`.
    public var grammar: String

    public init(oid: String, grammar: String) {
        self.oid = oid
        self.grammar = grammar
    }
}

/// What analyzing a version of a file found.
public struct BlobAnalysis: Sendable {
    /// The syntax tokens of each line, with ranges relative to the line.
    public var tokens: [[Token]]
    /// Its definitions, if it was analyzed for them.
    public var definitions: [Symbol]?

    /// About how much memory it holds.
    public var byteCount: Int { tokensByteCount(tokens) + symbolsByteCount(definitions ?? []) }
}

/// About how much memory tokens per line hold.
public func tokensByteCount(_ tokens: [[Token]]) -> Int {
    tokens.reduce(tokens.count * 32) { $0 + $1.count * MemoryLayout<Token>.stride }
}

/// About how much memory symbols hold, their names included.
public func symbolsByteCount(_ symbols: [Symbol]) -> Int {
    symbols.reduce(0) { $0 + MemoryLayout<Symbol>.stride + $1.name.utf8.count }
}

/// The syntax of file contents, analyzed once per version of the contents and grammar.
///
/// Contents are named by blob ID, so a version is analyzed once whichever snapshot, review or
/// reader shows it. Definitions are saved between launches; tokens are kept for the versions
/// used most recently, in the memory cache.
public actor ContentAnalysis {
    private let cache: URL?
    private let memory: MemoryCache
    private var definitions: [ContentKey: [Definition]] = [:]
    private var loaded = false
    private var unsaved = false
    private var saveScheduled = false
    private var saving: Task<Void, Never>?
    private var running: [ContentKey: (task: Task<BlobAnalysis, Never>, definitions: Bool)] = [:]

    /// Changes when what's saved changes shape or meaning, so older saves are dropped.
    static let format = 2

    /// - Parameters:
    ///   - cache: Where definitions are saved, or nil to keep them in memory.
    ///   - memory: Where analyses are kept while they may be asked for again.
    public init(cache: URL?, memory: MemoryCache = .shared) {
        self.cache = cache
        self.memory = memory
    }

    /// The key an analysis is kept under in the memory cache.
    private struct Kept: Hashable {
        var content: ContentKey
    }

    /// Returns the tokens of a version of a file, and its definitions if asked for, analyzing it
    /// unless it was analyzed before.
    ///
    /// - Parameters:
    ///   - lines: The file's lines, as `splitLines` gives them.
    ///   - oid: The blob ID of the file's contents.
    ///   - language: The grammar to parse it with.
    ///   - definitions: Whether to find its definitions too.
    public func analysis(of lines: [String], oid: String, language: SyntaxLanguage, definitions wanted: Bool) async -> BlobAnalysis {
        let key = ContentKey(oid: oid, grammar: language.version)
        let needsDefinitions = wanted && language.hasTags
        if let hit = memory.value(for: CacheKey(Kept(content: key))) as? BlobAnalysis, !needsDefinitions || hit.definitions != nil { return hit }
        if let r = running[key], r.definitions || !needsDefinitions { return await r.task.value }
        let task = Task.detached(priority: .userInitiated) { language.analysis(of: lines, definitions: needsDefinitions) }
        running[key] = (task, needsDefinitions)
        let found = await task.value
        if running[key]?.task == task { running[key] = nil }
        memory.insert(found, for: CacheKey(Kept(content: key)), bytes: found.byteCount)
        if let d = found.definitions {
            self.definitions[key] = indexedDefinitions(d)
            saveSoon()
        }
        return found
    }

    /// A version of a file to find definitions in.
    public struct Source: Sendable {
        /// The version git names, which the contents read are expected to have.
        public var key: ContentKey
        public var language: SyntaxLanguage
        /// Reads the contents, or returns nil when they can't be read now.
        public var read: @Sendable () async -> Data?

        public init(key: ContentKey, language: SyntaxLanguage, read: @escaping @Sendable () async -> Data?) {
            self.key = key
            self.language = language
            self.read = read
        }
    }

    /// The largest contents parsed for definitions, in bytes.
    public static let largestFile = 1 << 20

    /// Whether contents are worth parsing for definitions: not too large, and not binary.
    public static func isParseable(_ data: Data) -> Bool {
        data.count <= largestFile && !data.prefix(8000).contains(0)
    }

    /// Returns the definitions in some versions of files, reading and parsing in parallel those
    /// not analyzed before.
    ///
    /// What's read is named by its own blob ID, so a file that changed after git named it is
    /// saved as the version read, and a source that can't be read is left out and read again
    /// next time.
    ///
    /// - Parameter progress: Told how many versions are read of how many need it, as they finish.
    /// - Returns: The definitions of each source read, by the key it was asked for.
    public func definitions(of sources: [Source], progress: @escaping @Sendable (Int, Int) -> Void = { _, _ in }) async throws -> [ContentKey: [Definition]] {
        load()
        var seen = Set<ContentKey>()
        let missing = sources.filter { definitions[$0.key] == nil && seen.insert($0.key).inserted }
        var readAs: [ContentKey: ContentKey] = [:]
        if !missing.isEmpty {
            let workers = max(1, ProcessInfo.processInfo.activeProcessorCount - 2)
            try await withThrowingTaskGroup(of: Found?.self) { group in
                var next = 0
                func add() {
                    guard next < missing.count else { return }
                    let source = missing[next]
                    next += 1
                    group.addTask { try await Self.found(in: source, analysis: self) }
                }
                for _ in 0..<workers { add() }
                var done = 0
                for try await found in group {
                    if let found {
                        definitions[found.read] = found.definitions
                        readAs[found.asked] = found.read
                    }
                    done += 1
                    if done % 50 == 0 || done == missing.count { progress(done, missing.count) }
                    add()
                }
            }
            saveSoon()
        }
        var out: [ContentKey: [Definition]] = [:]
        for s in sources { out[s.key] = definitions[s.key] ?? readAs[s.key].flatMap { definitions[$0] } }
        return out
    }

    /// The definitions found in one source, under the key of the contents read.
    private struct Found: Sendable {
        var asked: ContentKey
        var read: ContentKey
        var definitions: [Definition]
    }

    private func saved(_ key: ContentKey) -> [Definition]? { definitions[key] }

    @concurrent private static func found(in source: Source, analysis: ContentAnalysis) async throws -> Found? {
        try Task.checkCancellation()
        guard let data = await source.read() else { return nil }
        let read = ContentKey(oid: blobID(of: data), grammar: source.key.grammar)
        if let saved = await analysis.saved(read) { return Found(asked: source.key, read: read, definitions: saved) }
        let found = isParseable(data)
            ? autoreleasepool { indexedDefinitions(source.language.symbols(splitLines(data).joined(separator: "\n"))) }
            : []
        return Found(asked: source.key, read: read, definitions: found)
    }

    /// Forgets the saved definitions of other versions once they outnumber these threefold, so
    /// what's saved stays near the size of the repository.
    ///
    /// No versions keep everything, since a snapshot without any says nothing about what's
    /// worth keeping.
    public func prune(keeping current: Set<ContentKey>) {
        guard !current.isEmpty, definitions.count > current.count * 3 else { return }
        definitions = definitions.filter { current.contains($0.key) }
        unsaved = true
        saveSoon()
    }

    /// Saves the definitions found so far, and waits until they're written.
    public func flush() async {
        save()
        await saving?.value
    }


    private struct Saved: Codable {
        var format: Int
        /// Definitions by grammar version, then by blob ID.
        var definitions: [String: [String: [Definition]]]
    }

    private func load() {
        guard !loaded else { return }
        loaded = true
        guard let cache, let data = try? Data(contentsOf: cache),
              let saved = try? JSONDecoder().decode(Saved.self, from: data), saved.format == Self.format else { return }
        for (grammar, blobs) in saved.definitions {
            for (oid, found) in blobs where definitions[ContentKey(oid: oid, grammar: grammar)] == nil {
                definitions[ContentKey(oid: oid, grammar: grammar)] = found
            }
        }
    }

    private func saveSoon() {
        unsaved = true
        guard loaded, !saveScheduled else { return }
        saveScheduled = true
        Task {
            try? await Task.sleep(for: .seconds(2))
            self.save()
        }
    }

    /// Writes the definitions off the actor, after any write already under way.
    ///
    /// Waits until the saved definitions are loaded, so they aren't overwritten by fewer.
    private func save() {
        saveScheduled = false
        guard loaded, unsaved, let cache else { return }
        unsaved = false
        let all = definitions, previous = saving
        saving = Task.detached(priority: .utility) {
            await previous?.value
            var grouped: [String: [String: [Definition]]] = [:]
            for (key, found) in all { grouped[key.grammar, default: [:]][key.oid] = found }
            guard let data = try? JSONEncoder().encode(Saved(format: Self.format, definitions: grouped)) else { return }
            try? FileManager.default.createDirectory(at: cache.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: cache, options: .atomic)
        }
    }
}

/// Returns the ID git gives a blob with these contents, in a repository that uses SHA-1.
public func blobID(of data: Data) -> String {
    var hash = Insecure.SHA1()
    hash.update(data: Data("blob \(data.count)\0".utf8))
    hash.update(data: data)
    return hash.finalize().map { String(format: "%02x", $0) }.joined()
}

extension SyntaxLanguage {
    /// Returns the tokens of some lines, and their definitions if asked for, parsing them as one
    /// text.
    ///
    /// A line's trailing CR is left out, so lines split from CRLF contents either way parse alike.
    public func analysis(of lines: [String], definitions: Bool) -> BlobAnalysis {
        let canonical = lines.map { $0.hasSuffix("\r") ? String($0.dropLast()) : $0 }
        let found = analyze(canonical.joined(separator: "\n"), symbols: definitions)
        return BlobAnalysis(tokens: tokensPerLine(found.tokens, lines: canonical),
                            definitions: definitions ? found.symbols.filter(\.isDefinition) : nil)
    }
}
