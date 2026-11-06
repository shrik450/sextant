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
}

/// The syntax of file contents, analyzed once per version of the contents and grammar.
///
/// Contents are named by blob ID, so a version is analyzed once whichever snapshot, review or
/// reader shows it. Definitions are saved between launches; tokens are kept for the versions
/// used most recently.
public actor ContentAnalysis {
    private let cache: URL?
    private var definitions: [ContentKey: [Definition]] = [:]
    private var loaded = false
    private var unsaved = false
    private var saveScheduled = false
    private var saving: Task<Void, Never>?
    private var recent = RecentlyUsed<ContentKey, BlobAnalysis>(budget: 1_000_000)
    private var running: [ContentKey: (task: Task<BlobAnalysis, Never>, definitions: Bool)] = [:]

    /// Changes when what's saved changes shape or meaning, so older saves are dropped.
    static let format = 2

    /// - Parameter cache: Where definitions are saved, or nil to keep them in memory.
    public init(cache: URL?) {
        self.cache = cache
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
        if let hit = recent.value(for: key), !needsDefinitions || hit.definitions != nil { return hit }
        if let r = running[key], r.definitions || !needsDefinitions { return await r.task.value }
        let task = Task.detached(priority: .userInitiated) { language.analysis(of: lines, definitions: needsDefinitions) }
        running[key] = (task, needsDefinitions)
        let found = await task.value
        if running[key]?.task == task { running[key] = nil }
        recent.insert(found, for: key, cost: found.tokens.reduce(found.tokens.count) { $0 + $1.count })
        if let d = found.definitions {
            self.definitions[key] = indexedDefinitions(d)
            saveSoon()
        }
        return found
    }

    /// A version of a file to find definitions in.
    public struct Source: Sendable {
        public var key: ContentKey
        public var language: SyntaxLanguage
        /// Reads the contents, or returns nil for contents not worth parsing.
        public var read: @Sendable () async -> Data?

        public init(key: ContentKey, language: SyntaxLanguage, read: @escaping @Sendable () async -> Data?) {
            self.key = key
            self.language = language
            self.read = read
        }
    }

    /// Returns the definitions in some versions of files, reading and parsing in parallel those
    /// not analyzed before.
    ///
    /// - Parameter progress: Told how many versions are parsed of how many need it, as they finish.
    public func definitions(of sources: [Source], progress: @escaping @Sendable (Int, Int) -> Void = { _, _ in }) async throws -> [ContentKey: [Definition]] {
        load()
        var seen = Set<ContentKey>()
        let missing = sources.filter { definitions[$0.key] == nil && seen.insert($0.key).inserted }
        if !missing.isEmpty {
            let workers = max(1, ProcessInfo.processInfo.activeProcessorCount - 2)
            try await withThrowingTaskGroup(of: (ContentKey, [Definition]).self) { group in
                var next = 0
                func add() {
                    guard next < missing.count else { return }
                    let source = missing[next]
                    next += 1
                    group.addTask { (source.key, try await Self.definitions(of: source)) }
                }
                for _ in 0..<workers { add() }
                var done = 0
                for try await (key, found) in group {
                    definitions[key] = found
                    done += 1
                    if done % 50 == 0 || done == missing.count { progress(done, missing.count) }
                    add()
                }
            }
            saveSoon()
        }
        var out: [ContentKey: [Definition]] = [:]
        for s in sources { out[s.key] = definitions[s.key] }
        return out
    }

    /// Forgets the saved definitions of other versions once they outnumber these threefold, so
    /// what's saved stays near the size of the repository.
    public func prune(keeping current: Set<ContentKey>) {
        guard definitions.count > current.count * 3 else { return }
        definitions = definitions.filter { current.contains($0.key) }
        unsaved = true
        saveSoon()
    }

    /// Saves the definitions found so far, and waits until they're written.
    public func flush() async {
        save()
        await saving?.value
    }

    @concurrent private static func definitions(of source: Source) async throws -> [Definition] {
        try Task.checkCancellation()
        guard let data = await source.read() else { return [] }
        return autoreleasepool { indexedDefinitions(source.language.symbols(splitLines(data).joined(separator: "\n"))) }
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

/// Values kept while their total cost stays within a budget, dropping the least recently used
/// first.
struct RecentlyUsed<Key: Hashable, Value> {
    private var entries: [Key: (value: Value, cost: Int, used: Int)] = [:]
    private var clock = 0
    /// The total cost of the values kept.
    private(set) var cost = 0
    let budget: Int

    init(budget: Int) {
        self.budget = budget
    }

    /// Returns a value, counting it as used.
    mutating func value(for key: Key) -> Value? {
        guard var e = entries[key] else { return nil }
        clock += 1
        e.used = clock
        entries[key] = e
        return e.value
    }

    /// Keeps a value, dropping the least recently used ones until the total fits the budget.
    ///
    /// A value that costs more than the whole budget isn't kept.
    mutating func insert(_ value: Value, for key: Key, cost c: Int) {
        if let old = entries.removeValue(forKey: key) { cost -= old.cost }
        guard c <= budget else { return }
        clock += 1
        entries[key] = (value, c, clock)
        cost += c
        while cost > budget, let oldest = entries.min(by: { $0.value.used < $1.value.used }) {
            entries[oldest.key] = nil
            cost -= oldest.value.cost
        }
    }
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
