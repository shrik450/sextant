import Foundation

public struct GitError: Error, LocalizedError, Sendable {
    /// Why git didn't give an answer.
    public enum Reason: Sendable, Equatable {
        /// It failed, couldn't run, or printed something that couldn't be read.
        case failed
        /// It printed more than the caller can use, so it was stopped.
        case outputTooLarge(limit: Int)
    }

    public var message: String
    public var reason: Reason

    public init(message: String, reason: Reason = .failed) {
        self.message = message
        self.reason = reason
    }

    public var errorDescription: String? { message }
}

/// A thin wrapper over the git CLI.
///
/// Every call is a separate process; git is fast, and this keeps results consistent with the
/// user's git config and on-disk state.
public struct Git: Sendable {
    public let root: URL
    public let executable: String
    /// The reader of the repository's objects, which the `Git`s for its checkouts share.
    let objects: ObjectReader

    /// A git for a repository, with its own reader of the repository's objects.
    ///
    /// For another checkout of the same repository, use `forCheckout(_:)` instead, to share
    /// the reader.
    public init(root: URL, executable: String) {
        self.init(root: root, executable: executable, objects: ObjectReader(directory: root, executable: executable))
    }

    private init(root: URL, executable: String, objects: ObjectReader) {
        self.root = root
        self.executable = executable
        self.objects = objects
    }

    /// A git for another checkout of the same repository, sharing this one's reader of its
    /// objects.
    public func forCheckout(_ root: URL) -> Git {
        Git(root: root, executable: executable, objects: objects)
    }

    /// How much a git command may print, by what its caller does with the output.
    ///
    /// A command that prints more is stopped, and its run throws a `GitError` whose reason is
    /// `.outputTooLarge`.
    public enum Limit {
        /// One value, such as an object ID, a ref, or one commit's message.
        public static let value = 1 << 20
        /// A list over the repository, such as its files, refs, commits, status or search results.
        public static let listing = 256 << 20
        /// A diff with its patches.
        public static let patch = 512 << 20
        /// One file's contents.
        public static let blob = 256 << 20
    }

    /// Runs git in a directory and returns what it prints.
    ///
    /// Cancelling the task stops git, and whatever it started, before the run throws
    /// `CancellationError`.
    ///
    /// - Parameters:
    ///   - priority: The quality of service git runs at. Work nobody is waiting on runs at
    ///     `.utility`, so it doesn't slow down what someone is.
    ///   - limit: The most bytes of output the caller can use (see `Limit`).
    /// - Throws: `GitError` when git fails or prints more than `limit`, and `CancellationError`
    ///   when the task is cancelled.
    public static func run(_ executable: String, in dir: URL, _ args: [String], stdin: Data? = nil, allowedStatuses: Set<Int32> = [0],
                           priority: QualityOfService = .userInitiated, limit: Int) async throws -> Data {
        var env = ProcessInfo.processInfo.environment
        env["GIT_OPTIONAL_LOCKS"] = "0"
        env["GIT_PAGER"] = "cat"
        env["GIT_TERMINAL_PROMPT"] = "0"
        env.removeValue(forKey: "GIT_DIR")
        env.removeValue(forKey: "GIT_WORK_TREE")
        let ran: ProcessOutput
        do {
            ran = try await runProcess(executable, ["-c", "core.quotePath=false", "-c", "color.ui=false", "-c", "log.showSignature=false"] + args,
                                       in: dir, environment: env, input: stdin, outputLimit: limit, qos: priority)
        } catch ProcessFailure.couldNotStart(let code) {
            throw GitError(message: "Couldn't run git at \(executable): \(String(cString: strerror(code)))")
        } catch ProcessFailure.outputTooLarge(let limit) {
            throw GitError(message: "git \(args.first ?? "") printed more than \(ByteCountFormatter.string(fromByteCount: Int64(limit), countStyle: .binary))",
                           reason: .outputTooLarge(limit: limit))
        }
        guard allowedStatuses.contains(ran.status) else {
            let msg = String(decoding: ran.errors, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            throw GitError(message: msg.isEmpty ? "git \(args.first ?? "") failed" : msg)
        }
        return ran.output
    }

    /// Runs git in the checkout and returns what it prints (see `run(_:in:_:stdin:allowedStatuses:priority:limit:)`).
    @discardableResult
    public func run(_ args: [String], stdin: Data? = nil, priority: QualityOfService = .userInitiated, limit: Int) async throws -> Data {
        try await Git.run(executable, in: root, args, stdin: stdin, priority: priority, limit: limit)
    }

    /// Runs git for one value, such as an object ID or a ref, and returns it trimmed.
    public func string(_ args: [String]) async throws -> String {
        String(decoding: try await run(args, limit: Limit.value), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public func optionalString(_ args: [String]) async -> String? {
        guard let s = try? await string(args), !s.isEmpty else { return nil }
        return s
    }

    /// Where a repository is: the checkout a path is in, and the git directory its worktrees
    /// share.
    public struct Location: Sendable {
        public var root: CanonicalPath
        public var commonDir: CanonicalPath
    }

    /// Finds the checkout and repository a path is in.
    public static func locate(_ path: URL, executable: String) async throws -> Location {
        let out = String(decoding: try await run(executable, in: path, ["rev-parse", "--show-toplevel", "--git-common-dir"], limit: Limit.value), as: UTF8.self)
        let lines = out.split(separator: "\n").map(String.init)
        guard lines.count >= 2 else { throw GitError(message: "\(path.path) is not inside a git work tree") }
        let common = lines[1].hasPrefix("/") ? URL(fileURLWithPath: lines[1]) : URL(fileURLWithPath: path.path).appendingPathComponent(lines[1])
        return Location(root: CanonicalPath(path: lines[0]), commonDir: CanonicalPath(common))
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
        let data = try await run(["log", "--format=" + logFormat, "--raw", "--no-abbrev", "-M", "--diff-merges=first-parent", "--skip=\(skip)", "-n", "\(count)", ref, "--"], limit: Limit.listing)
        return parseLog(data)
    }

    public func stashes() async -> [Stash] {
        guard let data = try? await run(["log", "--walk-reflogs", "--format=%x1e%H%x1f%P%x1f%gd%x1f%at%x1f%s", "refs/stash", "--"], limit: Limit.listing) else { return [] }
        return String(decoding: data, as: UTF8.self).split(separator: "\u{1e}").compactMap { r in
            let f = r.trimmingCharacters(in: .newlines).split(separator: "\u{1f}", omittingEmptySubsequences: false)
            guard f.count >= 5 else { return nil }
            return Stash(oid: String(f[0]), parents: f[1].split(separator: " ").map(String.init), ref: String(f[2]), date: Date(timeIntervalSince1970: TimeInterval(f[3]) ?? 0), subject: String(f[4]))
        }
    }

    public func commitDetail(_ oid: String) async throws -> CommitDetail {
        let s = String(decoding: try await run(["show", "-s", "--format=%H%x1f%P%x1f%an%x1f%ae%x1f%at%x1f%cn%x1f%ct%x1f%B", oid], limit: Limit.value), as: UTF8.self)
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
        async let patchData = run(["diff"] + Git.diffFlags + args + ["--"], limit: Limit.patch)
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
        let data = try await run(["ls-files", "--others", "--exclude-standard", "-z"], limit: Limit.listing)
        return data.split(separator: 0).map { String(decoding: $0, as: UTF8.self) }
    }

    /// Returns the ID git would give each worktree path's contents, without storing them.
    ///
    /// Regular files go through `git hash-object`, so the path's filters apply. A symbolic link
    /// is hashed here from its target path, which is what git stores for it.
    ///
    /// - Returns: An ID for each path, in order, or nil for a path that's neither a file this
    ///   process can read nor a symbolic link, such as a folder, a nested repository, or a file
    ///   deleted since it was listed.
    public func hashObjects(_ paths: [String]) async throws -> [String?] {
        var ids = [String?](repeating: nil, count: paths.count)
        var files: [Int] = []
        for (i, path) in paths.enumerated() {
            switch worktreeEntry(path) {
            case .file where isReadable(path): files.append(i)
            case .link(let target): ids[i] = blobID(of: target)
            default: break
            }
        }
        while !files.isEmpty {
            do {
                let input = Data(files.flatMap { stdinPathLine(paths[$0]) })
                let out = try await run(["hash-object", "--stdin-paths"], stdin: input, limit: Limit.listing)
                for (i, id) in zip(files, out.split(separator: 0x0A)) { ids[i] = String(decoding: id, as: UTF8.self) }
                break
            } catch {
                let before = files.count
                files.removeAll { worktreeEntry(paths[$0]) != .file || !isReadable(paths[$0]) }
                if files.count == before { throw error }
            }
        }
        return ids
    }

    /// Whether this process can read a worktree path.
    func isReadable(_ path: String) -> Bool { access(root.appendingPathComponent(path).path, R_OK) == 0 }

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

    /// Reads a worktree path the way git stores it: a regular file's contents, or a symbolic
    /// link's target path.
    ///
    /// The file is checked and read through one descriptor, so it can't be swapped for a link
    /// or grow past the limit in between.
    ///
    /// - Parameter limit: The most bytes to read.
    /// - Returns: Nil for a file larger than `limit`, or for a path that's neither a regular file
    ///   nor a symbolic link.
    public func readWorktreeFile(_ path: String, limit: Int = 4 << 20) -> Data? {
        let full = root.appendingPathComponent(path).path
        let fd = open(full, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { return errno == ELOOP ? readLink(full) : nil }
        defer { close(fd) }
        var st = stat()
        guard fstat(fd, &st) == 0, st.st_mode & S_IFMT == S_IFREG, st.st_size <= limit else { return nil }
        var data = Data(count: Int(st.st_size) + 1)
        var count = 0
        while true {
            if count == data.count {
                guard count <= limit else { return nil }
                data.count = min(count + (64 << 10), limit + 1)
            }
            let n = data.withUnsafeMutableBytes { read(fd, $0.baseAddress! + count, $0.count - count) }
            if n == 0 { break }
            if n < 0 {
                if errno == EINTR { continue }
                return nil
            }
            count += n
        }
        data.count = count
        return data
    }

    /// Old-side file lines, for expanding context around hunks.
    ///
    /// - Parameter limit: The most bytes of the old side the caller can use.
    /// - Returns: No lines for a file without an old side, like an added one.
    /// - Throws: `GitError` if the old side can't be read, or is larger than `limit` (reason
    ///   `.outputTooLarge`).
    public func oldLines(of file: FileDiff, limit: Int = Limit.blob) async throws -> [String] {
        guard file.change.oldOid != zeroOid else { return [] }
        return splitLines(try await blob(file.change.oldOid, limit: limit))
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

/// Returns a path's line for `git hash-object --stdin-paths`, which reads paths a line at a time
/// and has no NUL-separated form.
///
/// A path that holds a control character, like a newline, or starts with a quote is C-quoted,
/// which git unquotes. Others go as they are.
func stdinPathLine(_ path: String) -> [UInt8] {
    let bytes = Array(path.utf8)
    guard bytes.contains(where: { $0 < 0x20 || $0 == 0x7F }) || bytes.first == UInt8(ascii: "\"") else { return bytes + [0x0A] }
    var out: [UInt8] = [UInt8(ascii: "\"")]
    for byte in bytes {
        switch byte {
        case UInt8(ascii: "\""), UInt8(ascii: "\\"): out += [UInt8(ascii: "\\"), byte]
        case 0..<0x20, 0x7F: out += [UInt8(ascii: "\\")] + Array(String(format: "%03o", byte).utf8)
        default: out.append(byte)
        }
    }
    return out + [UInt8(ascii: "\""), 0x0A]
}
