/// Returns the value of `PATH` in what `env` prints, or nil if it isn't there.
///
/// A login shell's startup files may print their own lines, so only a line that starts with
/// `PATH=` counts, and the last one wins, since `env` runs after them.
public func pathVariable(inEnvironment output: String) -> String? {
    output.split(separator: "\n").last { $0.hasPrefix("PATH=") }.map { String($0.dropFirst("PATH=".count)) }
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
