import AppKit
import Foundation
import SextantCore

let usage = """
usage: sextant [path] [revision]

Opens the repository containing <path> (default: the current directory) in Sextant. <path> may
be a file. A lone argument that's both a revision and a path is an error: write ./<name> for
the path, or `sextant . <name>` for the revision.

revision:
  (none)            all the work in the checkout: its commits since the base branch,
                    and whatever isn't committed yet
  uncommitted       only what isn't committed yet
  staged            staged changes (also --staged, --cached)
  unstaged          unstaged changes
  <branch>          a branch, since it split from the base branch
  #<number>         an open pull request (needs the GitHub CLI)
  <commit>          one commit (sha, tag, HEAD~2, stash@{0}, …)
  <a>..<b>          the difference between two revisions (either may be left out for HEAD)
  <a>...<b>         the changes on <b> since it split from <a>
"""

func fail(_ msg: String) -> Never {
    FileHandle.standardError.write(Data(("sextant: " + msg + "\n").utf8))
    exit(1)
}

let args = Array(CommandLine.arguments.dropFirst())
if args.contains("-h") || args.contains("--help") {
    print(usage)
    exit(0)
}

func locateApp() -> URL? {
    let arg0 = CommandLine.arguments[0]
    let exe = URL(fileURLWithPath: arg0.contains("/") ? arg0 : (Bundle.main.executablePath ?? arg0)).resolvingSymlinksInPath()
    var dir = exe.deletingLastPathComponent()
    while dir.path != "/" {
        if dir.pathExtension == "app" { return dir }
        dir = dir.deletingLastPathComponent()
    }
    return NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.shrikanthup.Sextant")
}
guard let appURL = locateApp() else { fail("couldn't find Sextant.app") }

let environment = ProcessInfo.processInfo.environment
let told = [environment["SEXTANT_GIT"], Bundle(url: appURL)?.object(forInfoDictionaryKey: "SextantGitPath") as? String]
guard let git = told.compactMap({ $0 }).first(where: { FileManager.default.isExecutableFile(atPath: $0) }) ?? executable(named: "git", in: environment["PATH"] ?? "") else {
    fail("couldn't find git")
}

let request: OpenRequest
do {
    request = try await OpenRequest.read(args, in: URL(fileURLWithPath: FileManager.default.currentDirectoryPath), git: git)
} catch {
    fail(error.localizedDescription + (args.count > 2 ? "\n\n" + usage : ""))
}

var comps = URLComponents()
comps.scheme = "sextant"
comps.host = "open"
comps.queryItems = [URLQueryItem(name: "path", value: request.root)] + (request.revision.map { [URLQueryItem(name: "rev", value: $0)] } ?? [])
guard let url = comps.url else { fail("couldn't build URL") }

let config = NSWorkspace.OpenConfiguration()
config.activates = true
let opened: Error? = await withCheckedContinuation { done in
    NSWorkspace.shared.open([url], withApplicationAt: appURL, configuration: config) { _, error in done.resume(returning: error) }
}
if let opened { fail(opened.localizedDescription) }
