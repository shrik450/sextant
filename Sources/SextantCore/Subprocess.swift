import Darwin
import Dispatch
import Foundation
import Synchronization

/// What a program printed, and how it ended.
struct ProcessOutput: Sendable {
    /// The exit status, or 128 plus the signal that ended it.
    var status: Int32
    var output: Data
    /// What it printed to standard error, up to the run's error limit.
    var errors: Data
}

/// Why a program's run didn't give its output.
enum ProcessFailure: Error, Equatable {
    case couldNotStart(errno: Int32)
    /// It printed more than the caller can use, so it was stopped.
    case outputTooLarge(limit: Int)
}

/// The programs started by `runProcess(_:_:in:environment:input:outputLimit:errorLimit:qos:)`
/// that haven't ended yet.
public enum RunningProcesses {
    private static let live = Mutex(0)

    /// How many there are now.
    public static var count: Int { live.withLock { $0 } }

    fileprivate static func started() { live.withLock { $0 += 1 } }
    fileprivate static func ended() { live.withLock { $0 -= 1 } }
}

/// Runs a program in a process group of its own, and returns what it printed once it ends.
///
/// No thread waits on the program: its output and its end arrive through dispatch sources.
/// Cancelling the task stops the program and everything it started in its group, asking them
/// to end and killing them a second later if they haven't, and then throws `CancellationError`
/// once the program has ended. Output past `outputLimit` stops the program the same way and
/// throws `ProcessFailure.outputTooLarge`, so a caller never takes part of the output for all
/// of it.
///
/// - Parameters:
///   - path: The program's executable.
///   - arguments: The arguments after the program's name.
///   - directory: The directory it runs in.
///   - environment: Its whole environment.
///   - input: What it reads on standard input, or nil for `/dev/null`. A program may end
///     without reading all of it.
///   - outputLimit: The most bytes of standard output the caller can use.
///   - errorLimit: The most bytes of standard error kept; the rest is read and dropped.
///   - qos: The quality of service the program runs at, and its output is read at.
func runProcess(_ path: String, _ arguments: [String], in directory: URL, environment: [String: String], input: Data?,
                outputLimit: Int, errorLimit: Int = 64 << 10, qos: QualityOfService) async throws -> ProcessOutput {
    try Task.checkCancellation()
    let run = ProcessRun(outputLimit: outputLimit, errorLimit: errorLimit, input: input, qos: qos)
    return try await withTaskCancellationHandler {
        try await withCheckedThrowingContinuation { continuation in
            run.start(path, arguments, in: directory, environment: environment, continuation: continuation)
        }
    } onCancel: {
        run.cancel()
    }
}

/// One program's run, from its start until it has ended and been reaped.
///
/// Its state is only touched on its own serial queue. Every source is cancelled before the
/// run finishes, so none outlives it.
private final class ProcessRun: @unchecked Sendable {
    private let queue: DispatchQueue
    private let outputLimit: Int
    private let errorLimit: Int
    private let qos: QualityOfService
    private var input: Data?
    private var inputSent = 0

    private var pid: pid_t = 0
    private var continuation: CheckedContinuation<ProcessOutput, Error>?
    private var output = Data()
    private var errors = Data()
    private var outputSource: DispatchSourceRead?
    private var errorSource: DispatchSourceRead?
    private var inputSource: DispatchSourceWrite?
    private var exitSource: DispatchSourceProcess?
    private var killTimer: DispatchSourceTimer?
    private var ended = false
    private var failure: Error?
    private var cancelled = false

    init(outputLimit: Int, errorLimit: Int, input: Data?, qos: QualityOfService) {
        self.outputLimit = outputLimit
        self.errorLimit = errorLimit
        self.input = input
        self.qos = qos
        queue = DispatchQueue(label: "sextant.process", qos: DispatchQoS(qosClass: qos.dispatchClass, relativePriority: 0))
    }

    func start(_ path: String, _ arguments: [String], in directory: URL, environment: [String: String],
               continuation: CheckedContinuation<ProcessOutput, Error>) {
        queue.async { [self] in
            self.continuation = continuation
            guard !cancelled else { return finish(.failure(CancellationError())) }
            guard let out = makePipe() else { return finish(.failure(ProcessFailure.couldNotStart(errno: errno))) }
            guard let err = makePipe() else {
                closeBoth(out)
                return finish(.failure(ProcessFailure.couldNotStart(errno: errno)))
            }
            var inPipe: PipeEnds?
            if input != nil {
                inPipe = makePipe()
                guard inPipe != nil else {
                    closeBoth(out)
                    closeBoth(err)
                    return finish(.failure(ProcessFailure.couldNotStart(errno: errno)))
                }
            }
            let spawned = spawnProcessGroup(path, arguments, in: directory, environment: environment,
                                            input: inPipe?.read, output: out.write, errors: err.write, qos: qos.spawnClass, suspended: true)
            close(out.write)
            close(err.write)
            if let inPipe { close(inPipe.read) }
            guard case .success(let pid) = spawned else {
                close(out.read)
                close(err.read)
                if let inPipe { close(inPipe.write) }
                if case .failure(let failure) = spawned { finish(.failure(failure)) }
                return
            }
            self.pid = pid
            RunningProcesses.started()
            outputSource = readSource(out.read, atEnd: { [unowned self] in reapIfEnded() }) { [unowned self] in take(output: $0) }
            errorSource = readSource(err.read, atEnd: {}) { [unowned self] in take(errors: $0) }
            if let inPipe { inputSource = writeSource(inPipe.write) }
            let exit = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: queue)
            exit.setEventHandler { [unowned self] in reapIfEnded(exiting: true) }
            exit.setRegistrationHandler { kill(pid, SIGCONT) }
            exitSource = exit
            exit.resume()
            if cancelled { stop() }
        }
    }

    /// Stops the program, for a task that was cancelled.
    func cancel() {
        queue.async { [self] in
            guard !cancelled else { return }
            cancelled = true
            if failure == nil { failure = CancellationError() }
            if pid != 0, !ended { stop() }
        }
    }

    /// Asks the program's group to end, and kills it if the program hasn't a second later.
    private func stop() {
        guard killTimer == nil else { return }
        kill(-pid, SIGTERM)
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 1)
        timer.setEventHandler { [unowned self] in
            if !ended { kill(-pid, SIGKILL) }
        }
        killTimer = timer
        timer.resume()
    }

    /// Reads a descriptor as it's written to, and closes it at its end.
    ///
    /// - Parameter atEnd: Called once everything writing to it has closed it.
    private func readSource(_ fd: Int32, atEnd: @escaping () -> Void, _ take: @escaping (UnsafeRawBufferPointer) -> Void) -> DispatchSourceRead {
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [unowned source] in
            guard drain(fd, take) else { return }
            source.cancel()
            atEnd()
        }
        source.setCancelHandler { close(fd) }
        source.resume()
        return source
    }

    private func writeSource(_ fd: Int32) -> DispatchSourceWrite {
        _ = fcntl(fd, F_SETNOSIGPIPE, 1)
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        let source = DispatchSource.makeWriteSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [unowned self] in sendInput(fd) }
        source.setCancelHandler { close(fd) }
        source.resume()
        return source
    }

    private func take(output chunk: UnsafeRawBufferPointer) {
        guard failure == nil else { return }
        guard output.count + chunk.count <= outputLimit else {
            output = Data()
            failure = ProcessFailure.outputTooLarge(limit: outputLimit)
            stop()
            return
        }
        output.append(contentsOf: chunk)
    }

    private func take(errors chunk: UnsafeRawBufferPointer) {
        let room = errorLimit - errors.count
        if room > 0 { errors.append(contentsOf: chunk.prefix(room)) }
    }

    /// Writes as much of the input as the pipe takes, and closes it once it's all written, or
    /// the program has closed its end.
    private func sendInput(_ fd: Int32) {
        guard let input, failure == nil else { return stopInput() }
        let n = input.withUnsafeBytes { all in write(fd, all.baseAddress! + inputSent, all.count - inputSent) }
        if n > 0 {
            inputSent += n
            if inputSent == input.count { stopInput() }
        } else if n < 0, errno != EAGAIN, errno != EINTR {
            stopInput()
        }
    }

    private func stopInput() {
        input = nil
        inputSource?.cancel()
        inputSource = nil
    }

    /// Reaps the program once it has ended, and finishes the run.
    ///
    /// The program starts suspended and goes on once the exit source is installed, since a
    /// program that ends before then raises no event. It's checked on that event, and at the
    /// end of its output.
    ///
    /// Everything the program printed is in its pipes by the time it ends, so they're read to
    /// what's there and closed then, rather than when every holder closes them: something it
    /// left running in the background can keep them open. A program that was stopped takes
    /// what's left of its group with it.
    ///
    /// - Parameter exiting: Whether the program is known to be exiting, as the exit event says
    ///   before it can always be reaped, so this waits the moment until it can.
    private func reapIfEnded(exiting: Bool = false) {
        guard !ended else { return }
        var raw: Int32 = 0
        var r: pid_t
        repeat { r = waitpid(pid, &raw, exiting ? 0 : WNOHANG) } while r < 0 && errno == EINTR
        guard r == pid || (r < 0 && errno == ECHILD) else { return }
        ended = true
        RunningProcesses.ended()
        if let s = outputSource, !s.isCancelled {
            _ = drain(Int32(s.handle)) { [unowned self] in take(output: $0) }
            s.cancel()
        }
        if let s = errorSource, !s.isCancelled {
            _ = drain(Int32(s.handle)) { [unowned self] in take(errors: $0) }
            s.cancel()
        }
        stopInput()
        exitSource?.cancel()
        if let killTimer {
            killTimer.cancel()
            kill(-pid, SIGKILL)
        }
        if let failure { return finish(.failure(failure)) }
        finish(.success(ProcessOutput(status: r == pid ? exitStatus(raw) : -1, output: output, errors: errors)))
    }

    private func finish(_ result: Result<ProcessOutput, Error>) {
        continuation?.resume(with: result)
        continuation = nil
    }
}

/// Reads whatever a non-blocking descriptor holds now, a chunk at a time.
///
/// - Returns: Whether everything writing to it has closed it, or reading failed.
private func drain(_ fd: Int32, _ take: (UnsafeRawBufferPointer) -> Void) -> Bool {
    let size = 1 << 16
    let buffer = UnsafeMutableRawBufferPointer.allocate(byteCount: size, alignment: 1)
    defer { buffer.deallocate() }
    while true {
        let n = read(fd, buffer.baseAddress, size)
        if n > 0 {
            take(UnsafeRawBufferPointer(rebasing: buffer[..<n]))
            continue
        }
        if n < 0, errno == EINTR { continue }
        return n == 0 || errno != EAGAIN
    }
}

private func exitStatus(_ raw: Int32) -> Int32 {
    let signal = raw & 0x7f
    return signal == 0 ? (raw >> 8) & 0xff : 128 + signal
}

struct PipeEnds {
    var read: Int32
    var write: Int32
}

/// Makes a pipe whose ends close on exec.
///
/// Both ends block, as the child expects of its end; the parent makes its own end non-blocking
/// when it sets up the dispatch source that reads or writes it.
func makePipe() -> PipeEnds? {
    var ends: [Int32] = [0, 0]
    guard pipe(&ends) == 0 else { return nil }
    for fd in ends { _ = fcntl(fd, F_SETFD, FD_CLOEXEC) }
    return PipeEnds(read: ends[0], write: ends[1])
}

private func closeBoth(_ p: PipeEnds) {
    close(p.read)
    close(p.write)
}

/// Starts a program in a process group of its own, with the given descriptors as its standard
/// input, output and error, no other descriptor open, and every signal at its default.
///
/// - Parameters:
///   - input: Its standard input, or nil for `/dev/null`.
///   - errors: Its standard error, or nil for `/dev/null`.
///   - suspended: Whether it starts stopped, to go on when it's sent `SIGCONT`.
/// - Returns: Its process ID, which is also its group's.
func spawnProcessGroup(_ path: String, _ arguments: [String], in directory: URL, environment: [String: String],
                       input: Int32?, output: Int32, errors: Int32?, qos: qos_class_t, suspended: Bool = false) -> Result<pid_t, ProcessFailure> {
    var actions: posix_spawn_file_actions_t?
    posix_spawn_file_actions_init(&actions)
    defer { posix_spawn_file_actions_destroy(&actions) }
    if let input {
        posix_spawn_file_actions_adddup2(&actions, input, 0)
    } else {
        posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
    }
    posix_spawn_file_actions_adddup2(&actions, output, 1)
    if let errors {
        posix_spawn_file_actions_adddup2(&actions, errors, 2)
    } else {
        posix_spawn_file_actions_addopen(&actions, 2, "/dev/null", O_WRONLY, 0)
    }
    posix_spawn_file_actions_addchdir(&actions, directory.path)
    var attributes: posix_spawnattr_t?
    posix_spawnattr_init(&attributes)
    defer { posix_spawnattr_destroy(&attributes) }
    let flags = POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK
    posix_spawnattr_setflags(&attributes, Int16(flags | (suspended ? POSIX_SPAWN_START_SUSPENDED : 0)))
    posix_spawnattr_setpgroup(&attributes, 0)
    var noSignals = sigset_t(), everySignal = sigset_t()
    sigemptyset(&noSignals)
    sigfillset(&everySignal)
    posix_spawnattr_setsigmask(&attributes, &noSignals)
    posix_spawnattr_setsigdefault(&attributes, &everySignal)
    posix_spawnattr_set_qos_class_np(&attributes, qos)
    let argv = ([path] + arguments).map { strdup($0) } + [nil]
    let envp = environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
    defer {
        argv.forEach { free($0) }
        envp.forEach { free($0) }
    }
    var pid: pid_t = 0
    let r = posix_spawn(&pid, path, &actions, &attributes, argv, envp)
    return r == 0 ? .success(pid) : .failure(.couldNotStart(errno: r))
}

extension QualityOfService {
    fileprivate var dispatchClass: DispatchQoS.QoSClass {
        switch self {
        case .userInteractive: .userInteractive
        case .userInitiated: .userInitiated
        case .utility: .utility
        case .background: .background
        default: .default
        }
    }

    fileprivate var spawnClass: qos_class_t {
        switch self {
        case .userInteractive: QOS_CLASS_USER_INTERACTIVE
        case .userInitiated: QOS_CLASS_USER_INITIATED
        case .utility: QOS_CLASS_UTILITY
        case .background: QOS_CLASS_BACKGROUND
        default: QOS_CLASS_DEFAULT
        }
    }
}

/// Reaps a program that was killed, off the caller's thread, so it doesn't linger as a zombie.
func reapWhenEnded(_ pid: pid_t) {
    DispatchQueue.global(qos: .utility).async {
        var status: Int32 = 0
        while waitpid(pid, &status, 0) < 0, errno == EINTR {}
    }
}
