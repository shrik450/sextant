import Darwin
import Foundation

/// Reads the PATH a login shell sets up, by running its startup files.
///
/// The shell runs in its own process group, with its output read only until it exits: a
/// program its startup files leave running in the background can keep the output open, so
/// waiting for the end of it could take forever. If the shell is still running at the deadline,
/// its whole group is killed.
///
/// - Parameters:
///   - shell: The login shell's executable, such as the user's entry in the password database.
///   - timeout: How long the shell may take.
/// - Returns: The PATH, or nil if the shell couldn't be run, failed, or ran past the deadline.
public func readLoginShellPath(shell: String, timeout: Duration = .seconds(5)) -> String? {
    var ends: [Int32] = [0, 0]
    guard pipe(&ends) == 0 else { return nil }
    let (reading, writing) = (ends[0], ends[1])
    defer { close(reading) }
    guard let pid = spawnInOwnGroup(shell, ["-l", "-c", pathAfterMarkerCommand], output: writing) else {
        close(writing)
        return nil
    }
    close(writing)
    _ = fcntl(reading, F_SETFL, O_NONBLOCK)
    let deadline = ContinuousClock.now + timeout
    var output = Data()
    var status: Int32 = 0
    var exited = false
    while !exited {
        exited = waitpid(pid, &status, WNOHANG) == pid
        let ended = drain(reading, into: &output)
        if exited { break }
        if ContinuousClock.now >= deadline {
            kill(-pid, SIGKILL)
            waitpid(pid, &status, 0)
            return nil
        }
        if ended {
            usleep(10_000)
        } else {
            var poller = pollfd(fd: reading, events: Int16(POLLIN), revents: 0)
            _ = poll(&poller, 1, 10)
        }
    }
    guard status == 0 else { return nil }
    return pathAfterMarker(output)
}

/// What the login shell runs: a NUL, then PATH alone, so whatever its startup files print
/// before can't be read as PATH.
let pathAfterMarkerCommand = "/usr/bin/printf '\\0'; /usr/bin/printenv PATH"

/// Returns the PATH printed after the last NUL in a login shell's output, without the line
/// ending `printenv` adds.
///
/// - Returns: Nil if no NUL was printed, or PATH is empty.
public func pathAfterMarker(_ output: Data) -> String? {
    guard let marker = output.lastIndex(of: 0) else { return nil }
    var path = String(decoding: output[(marker + 1)...], as: UTF8.self)
    if path.hasSuffix("\n") { path.removeLast() }
    return path.isEmpty ? nil : path
}

/// Starts a program in a process group of its own, with standard input and error on
/// `/dev/null`, standard output on a descriptor, and no other descriptors open.
///
/// - Returns: The program's process ID, which is also its group's, or nil if it couldn't start.
private func spawnInOwnGroup(_ path: String, _ args: [String], output: Int32) -> pid_t? {
    var actions: posix_spawn_file_actions_t?
    posix_spawn_file_actions_init(&actions)
    defer { posix_spawn_file_actions_destroy(&actions) }
    posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
    posix_spawn_file_actions_adddup2(&actions, output, 1)
    posix_spawn_file_actions_addopen(&actions, 2, "/dev/null", O_WRONLY, 0)
    var attributes: posix_spawnattr_t?
    posix_spawnattr_init(&attributes)
    defer { posix_spawnattr_destroy(&attributes) }
    posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT))
    posix_spawnattr_setpgroup(&attributes, 0)
    let argv = ([path] + args).map { strdup($0) } + [nil]
    defer { argv.forEach { free($0) } }
    var pid: pid_t = 0
    return posix_spawn(&pid, path, &actions, &attributes, argv, environ) == 0 ? pid : nil
}

/// Reads whatever a non-blocking descriptor has now.
///
/// - Returns: Whether everything writing to it has closed it.
private func drain(_ fd: Int32, into data: inout Data) -> Bool {
    var buffer = [UInt8](repeating: 0, count: 16_384)
    while true {
        let n = read(fd, &buffer, buffer.count)
        guard n > 0 else { return n == 0 }
        data.append(buffer, count: n)
    }
}

/// Returns the PATH to find the user's tools on, each directory once.
///
/// The login shell's PATH comes first, since it's what the user runs in a terminal. Then the
/// usual places tools are installed, for when the shell couldn't be read, and last what the app
/// inherited, which for a GUI app is only the system's directories.
///
/// - Parameters:
///   - shell: The login shell's PATH, or nil if it couldn't be read.
///   - known: Directories tools are usually installed in, user ones before system ones.
///   - inherited: The PATH the process started with.
public func searchPath(shell: String?, known: [String], inherited: String?) -> String {
    let dirs = (shell ?? "").split(separator: ":").map(String.init) + known + (inherited ?? "").split(separator: ":").map(String.init)
    var seen = Set<String>()
    return dirs.filter { !$0.isEmpty && seen.insert($0).inserted }.joined(separator: ":")
}

/// Returns the first executable with a name in a PATH's directories.
///
/// - Parameters:
///   - name: The executable's name, such as `git`.
///   - path: Directories separated by colons.
public func executable(named name: String, in path: String) -> String? {
    path.split(separator: ":").map { "\($0)/\(name)" }.first { FileManager.default.isExecutableFile(atPath: $0) }
}
