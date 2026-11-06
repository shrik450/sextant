import Foundation

public struct GitError: Error, LocalizedError, Sendable {
    public var message: String
    public init(message: String) { self.message = message }
    public var errorDescription: String? { message }
}

/// A thin wrapper over the git CLI.
///
/// Every call is a separate process; git is fast, and this keeps results consistent with the
/// user's git config and on-disk state.
public struct Git: Sendable {
    public let root: URL
    public let executable: String

    public init(root: URL, executable: String) {
        self.root = root
        self.executable = executable
    }

    /// Runs git in a directory and returns what it prints.
    ///
    /// - Parameter priority: The quality of service git runs at. Work nobody is waiting on runs
    ///   at `.utility`, so it doesn't slow down what someone is.
    public static func run(_ executable: String, in dir: URL, _ args: [String], stdin: Data? = nil, allowedStatuses: Set<Int32> = [0], priority: QualityOfService = .userInitiated) async throws -> Data {
        try await withCheckedThrowingContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                let p = Process()
                p.executableURL = URL(fileURLWithPath: executable)
                p.arguments = ["-c", "core.quotePath=false", "-c", "color.ui=false", "-c", "log.showSignature=false"] + args
                p.qualityOfService = priority
                p.currentDirectoryURL = dir
                var env = ProcessInfo.processInfo.environment
                env["GIT_OPTIONAL_LOCKS"] = "0"
                env["GIT_PAGER"] = "cat"
                env["GIT_TERMINAL_PROMPT"] = "0"
                env.removeValue(forKey: "GIT_DIR")
                env.removeValue(forKey: "GIT_WORK_TREE")
                p.environment = env
                let out = Pipe(), err = Pipe()
                p.standardOutput = out
                p.standardError = err
                let inPipe = stdin.map { _ in Pipe() }
                p.standardInput = inPipe ?? FileHandle.nullDevice
                do {
                    try p.run()
                } catch {
                    cont.resume(throwing: GitError(message: "Couldn't run git at \(executable): \(error.localizedDescription)"))
                    return
                }
                if let stdin, let inPipe {
                    DispatchQueue.global().async {
                        try? inPipe.fileHandleForWriting.write(contentsOf: stdin)
                        try? inPipe.fileHandleForWriting.close()
                    }
                }
                let errData = LockedData()
                let g = DispatchGroup()
                g.enter()
                DispatchQueue.global().async {
                    errData.set(err.fileHandleForReading.readDataToEndOfFile())
                    g.leave()
                }
                let data = out.fileHandleForReading.readDataToEndOfFile()
                p.waitUntilExit()
                g.wait()
                if !allowedStatuses.contains(p.terminationStatus) {
                    let msg = String(decoding: errData.get(), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                    cont.resume(throwing: GitError(message: msg.isEmpty ? "git \(args.first ?? "") failed" : msg))
                } else {
                    cont.resume(returning: data)
                }
            }
        }
    }

    @discardableResult
    public func run(_ args: [String], stdin: Data? = nil, priority: QualityOfService = .userInitiated) async throws -> Data {
        try await Git.run(executable, in: root, args, stdin: stdin, priority: priority)
    }

    public func string(_ args: [String]) async throws -> String {
        String(decoding: try await run(args), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public func optionalString(_ args: [String]) async -> String? {
        guard let s = try? await string(args), !s.isEmpty else { return nil }
        return s
    }

    public struct Location: Sendable {
        public var root: URL
        public var commonDir: URL
    }

    public static func locate(_ path: URL, executable: String) async throws -> Location {
        let out = String(decoding: try await run(executable, in: path, ["rev-parse", "--show-toplevel", "--git-common-dir"]), as: UTF8.self)
        let lines = out.split(separator: "\n").map(String.init)
        guard lines.count >= 2 else { throw GitError(message: "\(path.path) is not inside a git work tree") }
        let root = URL(fileURLWithPath: lines[0], isDirectory: true)
        let common = lines[1].hasPrefix("/") ? URL(fileURLWithPath: lines[1], isDirectory: true) : URL(fileURLWithPath: lines[1], isDirectory: true, relativeTo: path).standardizedFileURL
        return Location(root: root, commonDir: common)
    }

    public func head() async -> String? { await optionalString(["rev-parse", "--verify", "-q", "HEAD"]) }
    public func currentBranch() async -> String? { await optionalString(["symbolic-ref", "-q", "--short", "HEAD"]) }

    /// The branch that work is usually compared against: origin's default, else main/master.
    public func defaultBranch() async -> String? {
        if let r = await optionalString(["symbolic-ref", "-q", "--short", "refs/remotes/origin/HEAD"]) { return r }
        for b in ["main", "master", "trunk", "origin/main", "origin/master"] {
            if await optionalString(["rev-parse", "--verify", "-q", b + "^{commit}"]) != nil { return b }
        }
        return nil
    }

    public func mergeBase(_ a: String, _ b: String) async -> String? { await optionalString(["merge-base", a, b]) }

    public func resolve(_ rev: String) async -> String? { await optionalString(["rev-parse", "--verify", "-q", rev + "^{commit}"]) }

    public func branches() async -> [String] {
        ((try? await string(["for-each-ref", "--format=%(refname:short)", "--sort=-committerdate", "refs/heads"])) ?? "")
            .split(separator: "\n").map(String.init)
    }

    public func log(_ ref: String, skip: Int, count: Int) async throws -> [Commit] {
        let data = try await run(["log", "--format=" + logFormat, "--raw", "--no-abbrev", "-M", "--diff-merges=first-parent", "--skip=\(skip)", "-n", "\(count)", ref, "--"])
        return parseLog(data)
    }

    public func stashes() async -> [Stash] {
        guard let data = try? await run(["log", "--walk-reflogs", "--format=%x1e%H%x1f%P%x1f%gd%x1f%at%x1f%s", "refs/stash", "--"]) else { return [] }
        return String(decoding: data, as: UTF8.self).split(separator: "\u{1e}").compactMap { r in
            let f = r.trimmingCharacters(in: .newlines).split(separator: "\u{1f}", omittingEmptySubsequences: false)
            guard f.count >= 5 else { return nil }
            return Stash(oid: String(f[0]), parents: f[1].split(separator: " ").map(String.init), ref: String(f[2]), date: Date(timeIntervalSince1970: TimeInterval(f[3]) ?? 0), subject: String(f[4]))
        }
    }

    public func commitDetail(_ oid: String) async throws -> CommitDetail {
        let s = String(decoding: try await run(["show", "-s", "--format=%H%x1f%P%x1f%an%x1f%ae%x1f%at%x1f%cn%x1f%ct%x1f%B", oid]), as: UTF8.self)
        let f = s.split(separator: "\u{1f}", maxSplits: 7, omittingEmptySubsequences: false).map(String.init)
        guard f.count == 8 else { throw GitError(message: "Unexpected output for \(oid)") }
        return CommitDetail(oid: f[0], parents: f[1].split(separator: " ").map(String.init), author: f[2], email: f[3],
                            authorDate: Date(timeIntervalSince1970: TimeInterval(f[4]) ?? 0), committer: f[5],
                            committerDate: Date(timeIntervalSince1970: TimeInterval(f[6]) ?? 0),
                            message: f[7].trimmingCharacters(in: .whitespacesAndNewlines))
    }


    static let diffFlags = ["--raw", "-p", "-z", "--no-abbrev", "--no-color", "--no-ext-diff", "--no-textconv", "--no-relative", "-M", "--submodule=short", "--src-prefix=a/", "--dst-prefix=b/"]

    /// Resolves the two sides of a target to arguments for `git diff`.
    public func diffArgs(_ target: Target) async throws -> [String] {
        switch target {
        case .worktree(let since?): return [since]
        case .worktree(nil): return [await head() ?? emptyTreeOid]
        case .staged: return ["--cached", await head() ?? emptyTreeOid]
        case .unstaged: return ["--ours"]
        case .commit(let c):
            let parent = await resolve(c + "^1")
            return [parent ?? emptyTreeOid, c]
        case .range(let base, let head): return [base, head]
        case .stash(let s): return [s + "^1", s]
        }
    }

    public func diff(_ target: Target) async throws -> [FileDiff] {
        let args = try await diffArgs(target)
        for _ in 0..<3 {
            let started = Date()
            let files = try await loadDiff(target, args: args)
            guard target.includesWorktree else { return files }
            let fm = FileManager.default
            let touched = files.contains { f in
                guard let m = (try? fm.attributesOfItem(atPath: root.appendingPathComponent(f.path).path))?[.modificationDate] as? Date else { return false }
                return m >= started
            }
            if !touched { return files }
        }
        return try await loadDiff(target, args: args)
    }

    private func loadDiff(_ target: Target, args: [String]) async throws -> [FileDiff] {
        async let patchData = run(["diff"] + Git.diffFlags + args + ["--"])
        async let untracked = target.includesWorktree ? untrackedFiles() : []
        var files = parseRawPatchZ(try await patchData)

        if target.includesWorktree {
            for i in files.indices where files[i].change.newMode == gitlinkMode && files[i].change.newOid == zeroOid {
                files[i].change.newOid = subprojectCommit(files[i]) ?? zeroOid
            }
            let unhashed = files.indices.filter { files[$0].change.newOid == zeroOid && !files[$0].change.isDeleted && files[$0].change.newMode != gitlinkMode }
            let extra = try await untracked
            let hashes = try await hashObjects(unhashed.map { files[$0].change.path } + extra)
            for (n, i) in unhashed.enumerated() { files[i].change.newOid = hashes[n] ?? zeroOid }
            for (n, path) in extra.enumerated() {
                if path.hasSuffix("/") {
                    files.append(untrackedRepositoryDiff(path: String(path.dropLast())))
                } else if let oid = hashes[unhashed.count + n] {
                    files.append(untrackedFileDiff(path: path, oid: oid, contents: readWorktreeFile(path), mode: worktreeMode(path)))
                }
            }
            files.sort { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
        }
        return files
    }

    /// Lists untracked files that aren't ignored, and repositories nested in the worktree, as
    /// their folder's path with a trailing `/`.
    public func untrackedFiles() async throws -> [String] {
        let data = try await run(["ls-files", "--others", "--exclude-standard", "-z"])
        return data.split(separator: 0).map { String(decoding: $0, as: UTF8.self) }
    }

    /// Returns the ID git would give each worktree path's contents, without storing them.
    ///
    /// Regular files go through `git hash-object`, so the path's filters apply. A symbolic link
    /// is hashed here from its target path, which is what git stores for it.
    ///
    /// - Returns: An ID for each path, in order, or nil for a path that's neither a file nor a
    ///   symbolic link, such as a folder, a nested repository, or a file deleted since it was
    ///   listed.
    public func hashObjects(_ paths: [String]) async throws -> [String?] {
        var ids = [String?](repeating: nil, count: paths.count)
        var files: [Int] = []
        for (i, path) in paths.enumerated() {
            switch worktreeEntry(path) {
            case .file: files.append(i)
            case .link(let target): ids[i] = blobID(of: target)
            case nil: break
            }
        }
        while !files.isEmpty {
            do {
                let input = Data(files.map { paths[$0] }.joined(separator: "\n").utf8 + [0x0A])
                let out = try await run(["hash-object", "--stdin-paths"], stdin: input)
                for (i, id) in zip(files, out.split(separator: 0x0A)) { ids[i] = String(decoding: id, as: UTF8.self) }
                break
            } catch {
                let before = files.count
                files.removeAll { worktreeEntry(paths[$0]) != .file }
                if files.count == before { throw error }
            }
        }
        return ids
    }

    /// What a worktree path holds, as git sees it.
    enum WorktreeEntry: Equatable {
        case file
        /// A symbolic link, with its target path as it's stored.
        case link(Data)
    }

    /// Returns what a worktree path is, without following a symbolic link, or nil if it's
    /// neither a regular file nor a symbolic link.
    func worktreeEntry(_ path: String) -> WorktreeEntry? {
        let full = root.appendingPathComponent(path).path
        var st = stat()
        guard lstat(full, &st) == 0 else { return nil }
        switch st.st_mode & S_IFMT {
        case S_IFREG: return .file
        case S_IFLNK: return readLink(full).map(WorktreeEntry.link)
        default: return nil
        }
    }

    /// Returns the mode git would record for a worktree file.
    ///
    /// This makes an untracked file's review key match the one it gets once committed.
    func worktreeMode(_ path: String) -> String {
        let p = root.appendingPathComponent(path).path
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: p) else { return "100644" }
        if attrs[.type] as? FileAttributeType == .typeSymbolicLink { return "120000" }
        let perms = (attrs[.posixPermissions] as? Int) ?? 0
        return perms & 0o100 != 0 ? "100755" : "100644"
    }

    public func readWorktreeFile(_ path: String, limit: Int = 4 << 20) -> Data? {
        let url = root.appendingPathComponent(path)
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attrs[.size] as? Int, size <= limit else { return nil }
        return try? Data(contentsOf: url)
    }

    /// Old-side file lines, for expanding context around hunks.
    public func oldLines(of file: FileDiff) async throws -> [String] {
        let c = file.change
        if c.oldOid != zeroOid { return splitLines(try await blob(c.oldOid)) }
        if c.newOid != zeroOid, let d = try? await blob(c.newOid) { return splitLines(d) }
        return splitLines(readWorktreeFile(c.path) ?? Data())
    }
}

/// The mode git records for a submodule.
let gitlinkMode = "160000"

/// Returns the commit a submodule's diff shows it moving to, without a `-dirty` mark.
func subprojectCommit(_ file: FileDiff) -> String? {
    let prefix = "Subproject commit "
    guard let line = file.hunks.last?.lines.last(where: { $0.kind != .deleted && $0.text.hasPrefix(prefix) }) else { return nil }
    let oid = line.text.dropFirst(prefix.count).prefix { $0.isHexDigit }
    return oid.count == zeroOid.count ? String(oid) : nil
}

/// Returns a symbolic link's target path as it's stored, byte for byte.
func readLink(_ path: String) -> Data? {
    var buffer = [UInt8](repeating: 0, count: Int(PATH_MAX) + 1)
    let n = readlink(path, &buffer, buffer.count)
    guard n >= 0 else { return nil }
    return Data(buffer[..<n])
}

final class LockedData: @unchecked Sendable {
    private var data = Data()
    private let lock = NSLock()
    func set(_ d: Data) { lock.lock(); data = d; lock.unlock() }
    func get() -> Data { lock.lock(); defer { lock.unlock() }; return data }
}
