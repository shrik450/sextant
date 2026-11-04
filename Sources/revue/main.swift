import AppKit
import Foundation

let usage = """
usage: revue [path] [revision]

Opens the repository containing <path> (default: the current directory) in Revue.

revision:
  (none)            all the work in the checkout: its commits since the base branch,
                    and whatever isn't committed yet
  uncommitted       only what isn't committed yet
  staged            staged changes
  unstaged          unstaged changes
  <branch>          a branch, since it split from the base branch
  #<number>         an open pull request (needs the GitHub CLI)
  <commit>          one commit (sha, tag, HEAD~2, stash@{0}, …)
  <a>..<b>          the difference between two revisions
  <a>...<b>         the changes on <b> since it split from <a>
"""

func fail(_ msg: String) -> Never {
    FileHandle.standardError.write(Data(("revue: " + msg + "\n").utf8))
    exit(1)
}

let args = Array(CommandLine.arguments.dropFirst())
if args.contains("-h") || args.contains("--help") {
    print(usage)
    exit(0)
}
if args.count > 2 { fail("too many arguments\n\n" + usage) }

let fm = FileManager.default
@MainActor func isDir(_ p: String) -> Bool {
    var d: ObjCBool = false
    return fm.fileExists(atPath: p, isDirectory: &d) && d.boolValue
}

var path = fm.currentDirectoryPath
var rev: String?
if args.count == 2 {
    path = args[0]
    rev = args[1]
} else if args.count == 1 {
    let a = args[0]
    let looksLikePath = a.hasPrefix("/") || a.hasPrefix("./") || a.hasPrefix("../") || a.hasPrefix("~") || a == "." || a == ".."
    if looksLikePath || isDir(a) { path = a } else { rev = a }
}
path = URL(fileURLWithPath: (path as NSString).expandingTildeInPath, relativeTo: URL(fileURLWithPath: fm.currentDirectoryPath)).standardizedFileURL.path
guard isDir(path) else { fail("\(path): not a directory") }

@MainActor func locateApp() -> URL? {
    let arg0 = CommandLine.arguments[0]
    let exe = URL(fileURLWithPath: arg0.contains("/") ? arg0 : (Bundle.main.executablePath ?? arg0)).resolvingSymlinksInPath()
    var dir = exe.deletingLastPathComponent()
    while dir.path != "/" {
        if dir.pathExtension == "app" { return dir }
        dir = dir.deletingLastPathComponent()
    }
    return NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.shrikanthup.Revue")
}
guard let appURL = locateApp() else { fail("couldn't find Revue.app") }

let gitCommand: [String] = {
    if let g = ProcessInfo.processInfo.environment["REVUE_GIT"], !g.isEmpty { return [g] }
    if let g = Bundle(url: appURL)?.object(forInfoDictionaryKey: "RevueGitPath") as? String, fm.isExecutableFile(atPath: g) { return [g] }
    return ["/usr/bin/env", "git"]
}()

@MainActor func git(_ a: [String]) -> (Int32, String) {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: gitCommand[0])
    p.arguments = Array(gitCommand.dropFirst()) + a
    p.currentDirectoryURL = URL(fileURLWithPath: path)
    let out = Pipe(), err = Pipe()
    p.standardOutput = out
    p.standardError = err
    do { try p.run() } catch { fail("couldn't run git: \(error.localizedDescription)") }
    let data = out.fileHandleForReading.readDataToEndOfFile()
    let errData = err.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    let s = String(decoding: p.terminationStatus == 0 ? data : errData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    return (p.terminationStatus, s)
}

let (status, top) = git(["rev-parse", "--show-toplevel"])
guard status == 0 else { fail("not a git repository: \(path)") }

if let r = rev, !["staged", "unstaged", "uncommitted", "cached", "worktree", "working", "wip", "index"].contains(r.lowercased()), !(r.hasPrefix("#") && Int(r.dropFirst()) != nil) {
    let sides: [String]
    if let range = r.range(of: "...") {
        sides = [String(r[..<range.lowerBound]), String(r[range.upperBound...])]
    } else if let range = r.range(of: "..") {
        sides = [String(r[..<range.lowerBound]), String(r[range.upperBound...])]
    } else {
        sides = [r]
    }
    for s in sides where !s.isEmpty {
        let (st, _) = git(["rev-parse", "--verify", "-q", s + "^{commit}"])
        if st != 0 { fail("unknown revision: \(s)") }
    }
}

var comps = URLComponents()
comps.scheme = "revue"
comps.host = "open"
comps.queryItems = [URLQueryItem(name: "path", value: top)] + (rev.map { [URLQueryItem(name: "rev", value: $0)] } ?? [])
guard let url = comps.url else { fail("couldn't build URL") }

final class Outcome: @unchecked Sendable {
    var error: Error?
    let done = DispatchSemaphore(value: 0)
}
let outcome = Outcome()
let config = NSWorkspace.OpenConfiguration()
config.activates = true
NSWorkspace.shared.open([url], withApplicationAt: appURL, configuration: config) { _, error in
    outcome.error = error
    outcome.done.signal()
}
while outcome.done.wait(timeout: .now()) == .timedOut {
    RunLoop.current.run(until: Date().addingTimeInterval(0.01))
}
if let error = outcome.error { fail(error.localizedDescription) }
