import Foundation
import SextantCore

/// A reviewer's note on some lines or on a whole review, which is the output of a review.
struct Note: Codable, Identifiable, Hashable {
    /// The lines a note is on.
    struct Lines: Codable, Hashable {
        var path: String
        /// The 1-based line numbers on the side the note was written on.
        var range: ClosedRange<Int>
        /// Whether the note is on removed lines (old side) rather than the new code.
        var old: Bool
        /// The code the note refers to.
        ///
        /// Notes only show next to that same code.
        var code: [String]

        var reference: String { lineReference(path: path, lines: range, old: old) }
    }

    var id = UUID()
    /// What the note was written about, as a `Subject.key`.
    var subject: String
    /// The lines the note is on, or nil for a note on the whole review.
    var lines: Lines?
    var text: String
    var created = Date()

    /// Where the note points, such as `src/a.rs:12`, or "Whole review".
    var title: String { lines?.reference ?? "Whole review" }
}

/// Formats a line reference as `path:12` or `path:12-15`, the form editors, terminals and
/// agents understand.
///
/// Removed lines are numbered as they were, and say so.
func lineReference(path: String, lines: ClosedRange<Int>, old: Bool) -> String {
    let l = lines.count == 1 ? "\(lines.lowerBound)" : "\(lines.lowerBound)-\(lines.upperBound)"
    return "\(path):\(l)" + (old ? " (removed)" : "")
}

/// Puts notes in reading order: notes on the whole review first, oldest first, then notes on
/// lines by file and line.
func readingOrder(_ notes: [Note]) -> [Note] {
    notes.sorted { a, b in
        switch (a.lines, b.lines) {
        case (nil, nil): a.created < b.created
        case (nil, _): true
        case (_, nil): false
        case (let x?, let y?): (x.path, x.range.lowerBound) < (y.path, y.range.lowerBound)
        }
    }
}

/// Renders notes as Markdown for pasting into a PR, a commit message or an agent prompt.
///
/// Notes on the whole review come first, as paragraphs, then notes on lines as a list.
func markdown(_ notes: [Note]) -> String {
    let ordered = readingOrder(notes)
    let general = ordered.filter { $0.lines == nil }.map(\.text)
    let onLines = ordered.compactMap { n in n.lines.map { (n, $0) } }.map { n, l in
        var s = "- `\(l.reference)`: \(n.text.replacingOccurrences(of: "\n", with: "\n  "))"
        if !l.code.isEmpty {
            let lang = SyntaxRuntime.shared?.language(forPath: l.path)?.name ?? ""
            s += "\n  ```\(lang)\n" + l.code.map { "  " + $0 }.joined(separator: "\n") + "\n  ```"
        }
        return s
    }
    return (general + (onLines.isEmpty ? [] : [onLines.joined(separator: "\n")])).joined(separator: "\n\n")
}

/// Notes for one repository, kept with its review state in the git dir.
@MainActor
final class NotesStore {
    static let didChange = Notification.Name("SextantNotesDidChange")
    private static var stores: [URL: NotesStore] = [:]

    static func shared(for commonDir: URL) -> NotesStore {
        let key = commonDir.standardizedFileURL
        if let s = stores[key] { return s }
        let s = NotesStore(url: key.appendingPathComponent("sextant/notes.json"))
        stores[key] = s
        return s
    }

    let url: URL
    private(set) var notes: [Note]

    private init(url: URL) {
        self.url = url
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        notes = (try? Data(contentsOf: url)).flatMap { try? dec.decode([Note].self, from: $0) } ?? []
    }

    /// The notes written about a subject, in reading order.
    func notes(about subject: Subject) -> [Note] { readingOrder(notes.filter { $0.subject == subject.key }) }

    func add(_ n: Note) { notes.append(n); save() }

    func update(_ n: Note) {
        guard let i = notes.firstIndex(where: { $0.id == n.id }) else { return }
        notes[i] = n
        save()
    }

    func remove(_ ids: Set<UUID>) {
        notes.removeAll { ids.contains($0.id) }
        save()
    }

    private func save() {
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let enc = JSONEncoder()
            enc.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            enc.dateEncodingStrategy = .iso8601
            try enc.encode(notes).write(to: url, options: .atomic)
        } catch {
            NSLog("Sextant: couldn't save notes to \(url.path): \(error)")
        }
        NotificationCenter.default.post(name: NotesStore.didChange, object: self)
    }
}
