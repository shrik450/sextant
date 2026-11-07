import Foundation
import SextantCore

/// What's been read and reviewed in one repository: files by blob transition (see
/// `RawChange.reviewKey`), and their runs of changes by `changeKeys(_:runs:)` in the file they
/// start from (see `RawChange.readingKey`).
///
/// The store lives in the repository's git dir, so it lives and dies with the clone.
@MainActor
final class ReviewStore {
    static let didChange = Notification.Name("SextantReviewStoreDidChange")
    private static var stores: [CanonicalPath: ReviewStore] = [:]

    static func shared(for commonDir: CanonicalPath) -> ReviewStore {
        let key = commonDir
        if let s = stores[key] { return s }
        let s = ReviewStore(directory: key.url.appendingPathComponent("sextant"))
        stores[key] = s
        return s
    }

    let directory: URL
    private(set) var state: ReadingState

    private var reviewedURL: URL { directory.appendingPathComponent("reviewed.json") }
    private var readURL: URL { directory.appendingPathComponent("read.json") }

    private init(directory: URL) {
        self.directory = directory
        func load<T: Decodable>(_ url: URL, as: T.Type) -> T? {
            (try? Data(contentsOf: url)).flatMap { try? JSONDecoder().decode(T.self, from: $0) }
        }
        let reviewed = load(directory.appendingPathComponent("reviewed.json"), as: [String: String].self) ?? [:]
        let read = load(directory.appendingPathComponent("read.json"), as: [String: ReadingState.Read].self) ?? [:]
        state = ReadingState(reviewed: reviewed, read: read)
    }

    func isReviewed(_ c: RawChange) -> Bool { state.isReviewed(c) }

    func isRead(_ change: String, in c: RawChange) -> Bool { state.isRead(change, in: c) }

    /// Marks files reviewed or not.
    ///
    /// - Parameters:
    ///   - changes: The files' changes.
    ///   - reviewed: Whether they're reviewed.
    ///   - keys: The keys of the runs of changes in each file, where they're known, so they stay
    ///     read once the file changes elsewhere.
    func set(_ changes: [RawChange], reviewed: Bool, keys: [RawChange: [String]] = [:], in review: Review) {
        update { $0.setReviewed(changes, to: reviewed, changes: keys, by: review.readingOwner) }
    }

    /// Marks a review's files reviewed or not, keeping the runs of changes in each file read once
    /// it changes elsewhere.
    func set(_ files: [FileState], reviewed: Bool, in review: Review) {
        let keys = reviewed ? Dictionary(files.map { ($0.diff.change, $0.changeKeys) }, uniquingKeysWith: { a, _ in a }) : [:]
        set(files.map(\.diff.change), reviewed: reviewed, keys: keys, in: review)
    }

    /// Marks one run of a file's changes read or unread.
    ///
    /// - Parameter all: The keys of every run of changes in the file.
    func setRead(_ change: String, in c: RawChange, all: [String], to value: Bool, in review: Review) {
        update { $0.setRead(change, in: c, all: all, to: value, by: review.readingOwner) }
    }

    /// Drops the changes a review read in files it no longer starts from, and the files it
    /// reviewed that it no longer shows, once it has loaded its changes again. Nothing shows
    /// them then, so it tells no one.
    ///
    /// - Parameter changes: The changes the review shows: its files' and its commits'.
    func prune(_ review: Review, showing changes: [RawChange]) {
        update(notifying: false) { $0.prune(owner: review.readingOwner, showing: changes) }
    }

    /// Returns how many of a commit's changes are reviewed, out of how many in total.
    func progress(_ changes: [RawChange]) -> (done: Int, total: Int) {
        (changes.reduce(0) { $0 + (state.isReviewed($1) ? 1 : 0) }, changes.count)
    }

    private func update(notifying: Bool = true, _ change: (inout ReadingState) -> Void) {
        var s = state
        change(&s)
        guard s != state else { return }
        let old = state
        state = s
        if s.reviewed != old.reviewed { save(s.reviewed, to: reviewedURL) }
        if s.read != old.read { save(s.read, to: readURL) }
        if notifying { NotificationCenter.default.post(name: ReviewStore.didChange, object: self) }
    }

    private func save(_ value: some Encodable, to url: URL) {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let enc = JSONEncoder()
            enc.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            try enc.encode(value).write(to: url, options: .atomic)
        } catch {
            NSLog("Sextant: couldn't save review state to \(url.path): \(error)")
        }
    }
}
