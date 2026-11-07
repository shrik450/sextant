import Darwin
import Foundation
import Synchronization

/// Reads objects through one long-running `git cat-file --batch` per object store, instead of
/// starting a process for each read.
///
/// Only reads that can't go stale go through it: object IDs, and paths in a commit named by
/// its ID. The batch process resolves names once, so the index or a moving ref would be read
/// as it was when the process started.
///
/// The `Git`s for a repository's checkouts share one reader (see `Git.forCheckout(_:)`). Its
/// process starts with the first read, and ends once no read has come for a while, or when the
/// last `Git` holding the reader goes away.
final class ObjectReader: @unchecked Sendable {
    private let directory: URL
    private let executable: String
    private let idleTimeout: DispatchTimeInterval
    private let queue = DispatchQueue(label: "sextant.cat-file", qos: .userInitiated)
    private var pid: pid_t = 0
    private var input: Int32 = -1
    private var output: Int32 = -1
    private let buffer = UnsafeMutableRawBufferPointer.allocate(byteCount: 1 << 16, alignment: 1)
    private var start = 0
    private var end = 0
    private var idleTimer: DispatchSourceTimer?

    /// The largest object skipped by reading past it, rather than ending the process, when it's
    /// not a blob or is larger than the caller can use.
    private static let largestSkipped = 16 << 20

    /// - Parameters:
    ///   - directory: Where the process runs: a checkout, or the repository's git directory.
    ///   - idleTimeout: How long the process stays without a read before it ends.
    init(directory: URL, executable: String, idleTimeout: DispatchTimeInterval = .seconds(20)) {
        self.directory = directory
        self.executable = executable
        self.idleTimeout = idleTimeout
    }

    deinit {
        idleTimer?.cancel()
        stop()
        buffer.deallocate()
    }

    /// Whether a name can be read through the batch process without going stale.
    static func canRead(_ name: String) -> Bool {
        guard !name.contains("\n") else { return false }
        let rev = name.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false).first ?? ""
        return rev.count == 40 && rev.allSatisfy(\.isHexDigit)
    }

    /// The batch process's ID while it runs.
    var processID: pid_t? { queue.sync { pid == 0 ? nil : pid } }

    /// Returns a blob's contents, or nil if the name doesn't name a blob.
    ///
    /// - Parameter limit: The most bytes the caller can use.
    /// - Throws: `GitError` with reason `.outputTooLarge` for a larger blob, and
    ///   `CancellationError` when the task is cancelled before its read starts.
    func blob(_ name: String, limit: Int) async throws -> Data? {
        let cancelled = Mutex(false)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                queue.async { [self] in
                    guard !cancelled.withLock({ $0 }) else { return continuation.resume(throwing: CancellationError()) }
                    var answer = read(name, limit: limit)
                    if case .failed = answer {
                        stop()
                        answer = read(name, limit: limit)
                    }
                    if case .failed = answer { stop() }
                    waitForIdle()
                    switch answer {
                    case .blob(let data): continuation.resume(returning: data)
                    case .notBlob, .failed: continuation.resume(returning: nil)
                    case .tooLarge:
                        let size = ByteCountFormatter.string(fromByteCount: Int64(limit), countStyle: .binary)
                        continuation.resume(throwing: GitError(message: "\(name) is larger than \(size)", reason: .outputTooLarge(limit: limit)))
                    }
                }
            }
        } onCancel: {
            cancelled.withLock { $0 = true }
        }
    }

    private enum Answer {
        case blob(Data)
        case notBlob
        case tooLarge
        /// The process couldn't answer, so the caller can start it again and retry once.
        case failed
    }

    private func read(_ name: String, limit: Int) -> Answer {
        guard startIfNeeded(), writeAll(Array((name + "\n").utf8)), let header = readLine() else { return .failed }
        let fields = header.split(separator: " ")
        guard fields.count == 3, let size = Int(fields[2]) else { return .notBlob }
        let isBlob = fields[1] == "blob"
        guard isBlob, size <= limit else {
            if size > Self.largestSkipped || !skip(size + 1) { stop() }
            return isBlob ? .tooLarge : .notBlob
        }
        guard let body = readBody(size) else { return .failed }
        return .blob(body)
    }

    private func startIfNeeded() -> Bool {
        if pid != 0 { return true }
        guard let toGit = makePipe() else { return false }
        guard let fromGit = makePipe() else {
            close(toGit.read)
            close(toGit.write)
            return false
        }
        var env = ProcessInfo.processInfo.environment
        env["GIT_OPTIONAL_LOCKS"] = "0"
        env.removeValue(forKey: "GIT_DIR")
        env.removeValue(forKey: "GIT_WORK_TREE")
        let spawned = spawnProcessGroup(executable, ["-c", "core.quotePath=false", "cat-file", "--batch"], in: directory, environment: env,
                                        input: toGit.read, output: fromGit.write, errors: nil, qos: QOS_CLASS_USER_INITIATED)
        close(toGit.read)
        close(fromGit.write)
        guard case .success(let started) = spawned else {
            close(toGit.write)
            close(fromGit.read)
            return false
        }
        pid = started
        input = toGit.write
        output = fromGit.read
        _ = fcntl(input, F_SETNOSIGPIPE, 1)
        return true
    }

    /// Ends the process, if it runs, and forgets what it had sent.
    private func stop() {
        guard pid != 0 else { return }
        close(input)
        close(output)
        kill(pid, SIGKILL)
        reapWhenEnded(pid)
        pid = 0
        input = -1
        output = -1
        start = 0
        end = 0
    }

    /// Ends the process once no read has come for the idle timeout.
    private func waitForIdle() {
        if idleTimer == nil {
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.setEventHandler { [weak self] in self?.stop() }
            timer.resume()
            idleTimer = timer
        }
        idleTimer?.schedule(deadline: .now() + idleTimeout)
    }

    private func writeAll(_ bytes: [UInt8]) -> Bool {
        var sent = 0
        while sent < bytes.count {
            let n = bytes[sent...].withUnsafeBytes { write(input, $0.baseAddress, $0.count) }
            if n < 0, errno == EINTR { continue }
            if n <= 0 { return false }
            sent += n
        }
        return true
    }

    /// Reads more of the process's output into the buffer, after what's unread in it.
    private func fill() -> Bool {
        if start > 0 {
            if end > start { buffer.baseAddress!.copyMemory(from: buffer.baseAddress! + start, byteCount: end - start) }
            end -= start
            start = 0
        }
        guard end < buffer.count else { return false }
        while true {
            let n = Darwin.read(output, buffer.baseAddress! + end, buffer.count - end)
            if n < 0, errno == EINTR { continue }
            guard n > 0 else { return false }
            end += n
            return true
        }
    }

    private func readLine() -> String? {
        var searchedFrom = start
        while true {
            if let nl = UnsafeRawBufferPointer(rebasing: buffer[searchedFrom..<end]).firstIndex(of: 0x0A) {
                let lineEnd = searchedFrom + nl
                let line = String(decoding: UnsafeRawBufferPointer(rebasing: buffer[start..<lineEnd]), as: UTF8.self)
                start = lineEnd + 1
                return line
            }
            let unread = end - start
            guard fill() else { return nil }
            searchedFrom = start + unread
        }
    }

    /// Reads a blob's contents and the line ending after them, into data the size of the
    /// blob, through the buffer.
    ///
    /// Reading straight into the data saves the copy, but writing a large blob into fresh pages
    /// from the kernel costs more than that copy does.
    private func readBody(_ size: Int) -> Data? {
        var data = Data()
        data.reserveCapacity(size)
        while data.count < size {
            if start == end, !fill() { return nil }
            let n = min(size - data.count, end - start)
            data.append(UnsafeRawBufferPointer(rebasing: buffer[start..<start + n]).assumingMemoryBound(to: UInt8.self))
            start += n
        }
        guard skip(1) else { return nil }
        return data
    }

    /// Reads past bytes of output without keeping them.
    private func skip(_ count: Int) -> Bool {
        var left = count
        while left > 0 {
            if start == end, !fill() { return false }
            let n = min(left, end - start)
            start += n
            left -= n
        }
        return true
    }
}

extension Git {
    /// Returns a blob's contents by object ID.
    ///
    /// - Parameter limit: The most bytes the caller can use.
    /// - Throws: `GitError` if there's no such blob, or it's larger than `limit` (reason
    ///   `.outputTooLarge`).
    public func blob(_ oid: String, limit: Int = Limit.blob) async throws -> Data {
        guard ObjectReader.canRead(oid) else { return try await run(["cat-file", "blob", oid], limit: limit) }
        guard let data = try await objects.blob(oid, limit: limit) else { throw GitError(message: "There’s no blob \(oid)") }
        return data
    }
}
