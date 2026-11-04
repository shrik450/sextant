import Foundation
import RevueCore

/// A reviewer's note on a range of lines, which is the output of a review.
struct Note: Codable, Identifiable, Hashable {
    var id = UUID()
    var path: String
    /// The 1-based line numbers on the side the note was written on.
    var lines: ClosedRange<Int>
    /// Whether the note is on removed lines (old side) rather than the new code.
    var old: Bool
    var text: String
    /// The code the note refers to.
    ///
    /// Notes only show next to that same code.
    var code: [String]
    /// What was being reviewed, such as "Uncommitted changes" or "a1b2c3d Fix parser".
    var context: String
    var created = Date()

    var reference: String { lineReference(path: path, lines: lines, old: old) }
}

/// Formats a line reference as `path:12` or `path:12-15`, the form editors, terminals and
/// agents understand.
///
/// Removed lines are numbered as they were, and say so.
func lineReference(path: String, lines: ClosedRange<Int>, old: Bool) -> String {
    let l = lines.count == 1 ? "\(lines.lowerBound)" : "\(lines.lowerBound)-\(lines.upperBound)"
    return "\(path):\(l)" + (old ? " (removed)" : "")
}

/// Notes for one repository, kept with its review state in the git dir.
@MainActor
final class NotesStore {
    static let didChange = Notification.Name("RevueNotesDidChange")
    private static var stores: [URL: NotesStore] = [:]

    static func shared(for commonDir: URL) -> NotesStore {
        let key = commonDir.standardizedFileURL
        if let s = stores[key] { return s }
        let s = NotesStore(url: key.appendingPathComponent("revue/notes.json"))
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

    func notes(for path: String) -> [Note] { notes.filter { $0.path == path } }

    /// Renders notes as Markdown for pasting into a PR, a commit message or an agent prompt.
    func markdown(_ selection: [Note]? = nil) -> String {
        let list = (selection ?? notes).sorted { ($0.path, $0.lines.lowerBound) < ($1.path, $1.lines.lowerBound) }
        return list.map { n in
            var s = "- `\(n.reference)`: \(n.text.replacingOccurrences(of: "\n", with: "\n  "))"
            if !n.code.isEmpty {
                let lang = SyntaxRuntime.shared?.language(forPath: n.path)?.name ?? ""
                s += "\n  ```\(lang)\n" + n.code.map { "  " + $0 }.joined(separator: "\n") + "\n  ```"
            }
            return s
        }.joined(separator: "\n")
    }

    private func save() {
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let enc = JSONEncoder()
            enc.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            enc.dateEncodingStrategy = .iso8601
            try enc.encode(notes).write(to: url, options: .atomic)
        } catch {
            NSLog("Revue: couldn't save notes to \(url.path): \(error)")
        }
        NotificationCenter.default.post(name: NotesStore.didChange, object: self)
    }
}
