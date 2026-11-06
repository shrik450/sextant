import Foundation
import SextantCore

/// What's been read and reviewed in one repository: files by blob transition (see
/// `RawChange.reviewKey`) and their runs of changes by `changeKey`.
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
        func load(_ url: URL) -> Set<String> {
            (try? Data(contentsOf: url)).flatMap { try? JSONDecoder().decode([String].self, from: $0) }.map(Set.init) ?? []
        }
        state = ReadingState(reviewed: load(directory.appendingPathComponent("reviewed.json")), read: load(directory.appendingPathComponent("read.json")))
    }

    func isReviewed(_ c: RawChange) -> Bool { state.isReviewed(c.reviewKey) }

    func isRead(_ change: String, in c: RawChange) -> Bool { state.isRead(change, in: c.reviewKey) }

    func set(_ changes: [RawChange], reviewed: Bool) {
        update { $0.setReviewed(changes.map(\.reviewKey), to: reviewed) }
    }

    /// Marks one run of a file's changes read or unread.
    ///
    /// - Parameter all: The keys of every run of changes in the file.
    func setRead(_ change: String, in c: RawChange, all: [String], to value: Bool) {
        update { $0.setRead(change, in: c.reviewKey, all: all, to: value) }
    }

    /// Returns how many of a commit's changes are reviewed, out of how many in total.
    func progress(_ changes: [RawChange]) -> (done: Int, total: Int) {
        (changes.reduce(0) { $0 + (state.isReviewed($1.reviewKey) ? 1 : 0) }, changes.count)
    }

    private func update(_ change: (inout ReadingState) -> Void) {
        var s = state
        change(&s)
        guard s != state else { return }
        state = s
        save(s.reviewed, to: reviewedURL)
        save(s.read, to: readURL)
        NotificationCenter.default.post(name: ReviewStore.didChange, object: self)
    }

    private func save(_ keys: Set<String>, to url: URL) {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let enc = JSONEncoder()
            enc.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes]
            try enc.encode(keys.sorted()).write(to: url, options: .atomic)
        } catch {
            NSLog("Sextant: couldn't save review state to \(url.path): \(error)")
        }
    }
}
