import Foundation
import RevueCore

/// The reviewed changes for one repository, keyed by blob transition (see `RawChange.reviewKey`).
///
/// The store lives in the repository's git dir, so it lives and dies with the clone.
@MainActor
final class ReviewStore {
    static let didChange = Notification.Name("RevueReviewStoreDidChange")
    private static var stores: [URL: ReviewStore] = [:]

    static func shared(for commonDir: URL) -> ReviewStore {
        let key = commonDir.standardizedFileURL
        if let s = stores[key] { return s }
        let s = ReviewStore(url: key.appendingPathComponent("revue/reviewed.json"))
        stores[key] = s
        return s
    }

    let url: URL
    private(set) var keys: Set<String>

    private init(url: URL) {
        self.url = url
        if let data = try? Data(contentsOf: url), let arr = try? JSONDecoder().decode([String].self, from: data) {
            keys = Set(arr)
        } else {
            keys = []
        }
    }

    func isReviewed(_ c: RawChange) -> Bool { keys.contains(c.reviewKey) }

    func set(_ changes: [RawChange], reviewed: Bool) {
        var k = keys
        for c in changes {
            if reviewed { k.insert(c.reviewKey) } else { k.remove(c.reviewKey) }
        }
        guard k != keys else { return }
        keys = k
        save()
        NotificationCenter.default.post(name: ReviewStore.didChange, object: self)
    }

    /// Returns how many of a commit's changes are reviewed, out of how many in total.
    func progress(_ changes: [RawChange]) -> (done: Int, total: Int) {
        (changes.reduce(0) { $0 + (keys.contains($1.reviewKey) ? 1 : 0) }, changes.count)
    }

    private func save() {
        let sorted = keys.sorted()
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let enc = JSONEncoder()
            enc.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes]
            try enc.encode(sorted).write(to: url, options: .atomic)
        } catch {
            NSLog("Revue: couldn't save review state to \(url.path): \(error)")
        }
    }
}
