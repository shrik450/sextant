import Foundation

/// Reads objects through one long-running `git cat-file --batch` per repository, instead of
/// starting a process for each read.
///
/// Only reads that can't go stale go through it: object IDs, and paths in a commit named by
/// its ID. The batch process resolves names once, so the index or a moving ref would be read
/// as it was when the process started.
final class ObjectReader: @unchecked Sendable {
    private let root: URL
    private let executable: String
    private let queue = DispatchQueue(label: "sextant.cat-file", qos: .userInitiated)
    private var process: Process?
    private var input: Int32 = -1
    private var output: Int32 = -1
    private var buffer: [UInt8] = []
    private var position = 0

    private init(root: URL, executable: String) {
        self.root = root
        self.executable = executable
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var readers: [String: ObjectReader] = [:]

    /// The reader for a repository, started on its first read and kept for the app's lifetime.
    static func shared(root: URL, executable: String) -> ObjectReader {
        lock.lock()
        defer { lock.unlock() }
        let key = executable + "|" + root.standardizedFileURL.path
        if let r = readers[key] { return r }
        let r = ObjectReader(root: root, executable: executable)
        readers[key] = r
        return r
    }

    /// Whether a name can be read through the batch process without going stale.
    static func canRead(_ name: String) -> Bool {
        guard !name.contains("\n") else { return false }
        let rev = name.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false).first ?? ""
        return rev.count == 40 && rev.allSatisfy(\.isHexDigit)
    }

    /// Returns a blob's contents, or nil if the name doesn't name a blob.
    func blob(_ name: String) async -> Data? {
        await withCheckedContinuation { c in
            queue.async {
                if let data = self.read(name) {
                    c.resume(returning: data)
                } else {
                    self.stop()
                    c.resume(returning: self.read(name) ?? nil)
                }
            }
        }
    }

    /// Reads one object, or returns nil if the process failed, so the caller can retry once.
    ///
    /// - Returns: The blob's contents, `.some(nil)` if the name doesn't name a blob, or nil if
    ///   the process couldn't answer.
    private func read(_ name: String) -> Data?? {
        guard start() else { return nil }
        let request = Array((name + "\n").utf8)
        guard writeAll(request) else { return nil }
        guard let header = readLine() else { return nil }
        let fields = header.split(separator: " ")
        guard fields.count == 3, let size = Int(fields[2]) else { return .some(nil) }
        guard let body = read(count: size + 1) else { return nil }
        return fields[1] == "blob" ? .some(Data(body.dropLast())) : .some(nil)
    }

    private func start() -> Bool {
        if let p = process, p.isRunning { return true }
        stop()
        let p = Process()
        p.executableURL = URL(fileURLWithPath: executable)
        p.arguments = ["-c", "core.quotePath=false", "cat-file", "--batch"]
        p.currentDirectoryURL = root
        var env = ProcessInfo.processInfo.environment
        env["GIT_OPTIONAL_LOCKS"] = "0"
        env.removeValue(forKey: "GIT_DIR")
        env.removeValue(forKey: "GIT_WORK_TREE")
        p.environment = env
        let inPipe = Pipe(), outPipe = Pipe()
        p.standardInput = inPipe
        p.standardOutput = outPipe
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return false }
        input = dup(inPipe.fileHandleForWriting.fileDescriptor)
        output = dup(outPipe.fileHandleForReading.fileDescriptor)
        _ = fcntl(input, F_SETNOSIGPIPE, 1)
        process = p
        return true
    }

    private func stop() {
        if input >= 0 { close(input) }
        if output >= 0 { close(output) }
        input = -1
        output = -1
        process?.terminate()
        process = nil
        buffer = []
        position = 0
    }

    private func writeAll(_ bytes: [UInt8]) -> Bool {
        var sent = 0
        while sent < bytes.count {
            let n = bytes[sent...].withUnsafeBytes { write(input, $0.baseAddress, $0.count) }
            if n <= 0 { return false }
            sent += n
        }
        return true
    }

    private func fill() -> Bool {
        if position > 0 {
            buffer.removeFirst(position)
            position = 0
        }
        var chunk = [UInt8](repeating: 0, count: 1 << 16)
        let n = chunk.withUnsafeMutableBytes { Foundation.read(output, $0.baseAddress, $0.count) }
        guard n > 0 else { return false }
        buffer += chunk[..<n]
        return true
    }

    private func readLine() -> String? {
        while true {
            if let nl = buffer[position...].firstIndex(of: 0x0A) {
                let line = String(decoding: buffer[position..<nl], as: UTF8.self)
                position = nl + 1
                return line
            }
            guard fill() else { return nil }
        }
    }

    private func read(count: Int) -> [UInt8]? {
        if buffer.count - position < count {
            buffer.reserveCapacity(position + count)
            while buffer.count - position < count {
                guard fill() else { return nil }
            }
        }
        let out = Array(buffer[position..<position + count])
        position += count
        return out
    }
}

extension Git {
    /// The batch reader for this repository's objects.
    var objects: ObjectReader { ObjectReader.shared(root: root, executable: executable) }

    /// Returns a blob's contents by object ID.
    public func blob(_ oid: String) async throws -> Data {
        if ObjectReader.canRead(oid) {
            guard let data = await objects.blob(oid) else { throw GitError(message: "There’s no blob \(oid)") }
            return data
        }
        return try await run(["cat-file", "blob", oid])
    }
}
