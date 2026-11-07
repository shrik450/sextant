import Foundation

/// What the `sextant` command asks the app to open: a checkout, and what to review in it.
public struct OpenRequest: Equatable, Sendable {
    /// The checkout's top-level folder.
    public var root: String
    /// The revision expression to review, as typed, or nil for all the work in the checkout.
    public var revision: String?

    public init(root: String, revision: String?) {
        self.root = root
        self.revision = revision
    }

    /// Reads the `sextant` command's arguments, `[path] [revision]`, checking them with git as
    /// the app will.
    ///
    /// A lone argument is a path when it's written like one (`/…`, `./…`, `../…`, `~…`, `.`,
    /// `..`), and a revision when it's one of the app's words (`staged`, `#12`, …). Otherwise it's
    /// whichever of the two it names, and an error when it names both, as git's own commands
    /// treat a name that's both a revision and a file. A path may be a file, which opens the
    /// checkout it's in.
    ///
    /// - Parameters:
    ///   - arguments: The arguments after the command's name.
    ///   - directory: The folder relative paths start from.
    ///   - git: The git executable.
    /// - Throws: `GitError` saying what's wrong with the arguments.
    public static func read(_ arguments: [String], in directory: URL, git: String) async throws -> OpenRequest {
        var path = directory.path
        var revision: String?
        switch arguments.count {
        case 0: break
        case 1:
            let a = arguments[0]
            if writtenAsPath(a) {
                path = a
            } else if let spec = parseRevisionSpec(a), spec.needsNoLookup {
                revision = a
            } else {
                let isPath = FileManager.default.fileExists(atPath: resolve(a, in: directory).path)
                let missing = await unresolved(a, in: directory, git: git)
                switch (isPath, missing) {
                case (true, nil): throw GitError(message: "‘\(a)’ is both a revision and a path: write ./\(a) for the path, or ‘sextant . \(a)’ for the revision")
                case (true, _): path = a
                case (false, nil): revision = a
                case (false, let missing?):
                    guard case .comparison? = parseRevisionSpec(a) else { throw GitError(message: "‘\(a)’ is neither a revision nor a path") }
                    throw GitError(message: "unknown revision: \(missing)")
                }
            }
        case 2:
            path = arguments[0]
            revision = arguments[1]
        default:
            throw GitError(message: "too many arguments")
        }
        let url = resolve(path, in: directory)
        var isFolder: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isFolder) else { throw GitError(message: "\(url.path): no such file or folder") }
        let folder = isFolder.boolValue ? url : url.deletingLastPathComponent()
        guard let root = try? await Git.run(git, in: folder, ["rev-parse", "--show-toplevel"]) else { throw GitError(message: "not a git repository: \(url.path)") }
        let checkout = String(decoding: root, as: UTF8.self).trimmingCharacters(in: .newlines)
        if let revision, let missing = await unresolved(revision, in: URL(fileURLWithPath: checkout), git: git) {
            throw GitError(message: "unknown revision: \(missing)")
        }
        return OpenRequest(root: checkout, revision: revision.flatMap { parseRevisionSpec($0) == nil ? nil : $0 })
    }

    private static func writtenAsPath(_ a: String) -> Bool {
        a == "." || a == ".." || ["/", "./", "../", "~"].contains { a.hasPrefix($0) }
    }

    private static func resolve(_ path: String, in directory: URL) -> URL {
        URL(fileURLWithPath: (path as NSString).expandingTildeInPath, relativeTo: directory).standardizedFileURL
    }

    /// Returns the first revision a revision expression names that git can't find as a commit,
    /// looked up as the app looks them up.
    ///
    /// - Returns: Nil when every revision is found, or when the expression names none, such as
    ///   `staged`.
    private static func unresolved(_ expression: String, in directory: URL, git: String) async -> String? {
        let revisions: [String] = switch parseRevisionSpec(expression) {
        case .revision(let r)?: [r]
        case .comparison(let from, let to, _)?: [from, to]
        default: []
        }
        let repo = Git(root: directory, executable: git)
        for r in revisions where await repo.resolve(r) == nil { return r }
        return nil
    }
}

extension RevisionSpec {
    /// Whether the spec names what to review without any refs to look up, such as `staged` or a
    /// pull request.
    var needsNoLookup: Bool {
        switch self {
        case .uncommitted, .staged, .unstaged, .pullRequest: true
        case .comparison, .revision: false
        }
    }
}
