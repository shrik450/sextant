import Darwin
import Foundation
import Testing
@testable import SextantCore

@Test func readsPathAfterTheLastMarker() {
    #expect(pathAfterMarker(Data("Welcome!\nPATH=/old\n\0/nix/bin:/usr/bin\n".utf8)) == "/nix/bin:/usr/bin")
    #expect(pathAfterMarker(Data("\0junk\0/usr/bin".utf8)) == "/usr/bin")
}

@Test func hasNoPathWithoutAMarkerOrAfterAnEmptyOne() {
    #expect(pathAfterMarker(Data("PATH=/usr/bin\n".utf8)) == nil)
    #expect(pathAfterMarker(Data("\0\n".utf8)) == nil)
}

@Test func putsTheShellsPathBeforeTheSystemsStub() {
    let path = searchPath(shell: "/opt/homebrew/bin:/Users/a/.nix-profile/bin:/usr/bin", known: ["/Users/a/.nix-profile/bin", "/usr/bin"], inherited: "/usr/bin:/bin")
    #expect(path == "/opt/homebrew/bin:/Users/a/.nix-profile/bin:/usr/bin:/bin")
}

@Test func putsKnownToolDirectoriesBeforeInheritedOnesWithoutAShell() {
    let path = searchPath(shell: nil, known: ["/Users/a/.nix-profile/bin", "/usr/bin"], inherited: "/usr/bin:/bin:/usr/sbin")
    #expect(path == "/Users/a/.nix-profile/bin:/usr/bin:/bin:/usr/sbin")
}

/// Runs login shells written in the test, which take `-l -c <command>` as a real one does.
@Suite struct LoginShellTests {
    /// Writes a login shell that runs some lines of its own, then the command it's given.
    ///
    /// - Parameter name: The script's file name.
    /// - Returns: The script's path.
    func shell(_ name: String, _ lines: String) throws -> String {
        let dir = GitIntegrationTests.root.appendingPathComponent(".build/test-repos/shells", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(name)
        try Data("#!/bin/bash\n\(lines)\n".utf8).write(to: url)
        chmod(url.path, 0o755)
        return url.path
    }

    @Test func readsThePathTheShellSetsPastWhatItPrintsAndOtherVariables() throws {
        let sh = try shell("chatty", """
        echo 'Welcome!'
        echo 'PATH=/printed'
        export PATH=/real/bin:/usr/bin:/bin
        export SPOOF=$'one\\nPATH=/spoofed'
        exec /bin/sh -c "$3"
        """)
        #expect(readLoginShellPath(shell: sh) == "/real/bin:/usr/bin:/bin")
    }

    @Test func stopsReadingWhenTheShellExitsThoughAProgramItStartedKeepsItsOutput() throws {
        let sh = try shell("lingering", """
        export PATH=/real/bin:/usr/bin:/bin
        /bin/sleep 30 &
        exec /bin/sh -c "$3"
        """)
        let start = ContinuousClock.now
        #expect(readLoginShellPath(shell: sh, timeout: .seconds(10)) == "/real/bin:/usr/bin:/bin")
        #expect(ContinuousClock.now - start < .seconds(2))
    }

    @Test func givesUpOnAShellThatHangsAndStopsWhatItStarted() async throws {
        let pidFile = GitIntegrationTests.root.appendingPathComponent(".build/test-repos/shells/hanging.pid")
        try? FileManager.default.removeItem(at: pidFile)
        let sh = try shell("hanging", """
        /bin/sleep 30 &
        echo $! > '\(pidFile.path)'
        /bin/sleep 30
        """)
        let start = ContinuousClock.now
        #expect(readLoginShellPath(shell: sh, timeout: .milliseconds(500)) == nil)
        #expect(ContinuousClock.now - start < .seconds(2))
        let started = try #require(Int32(String(decoding: try Data(contentsOf: pidFile), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)))
        var alive = true
        for _ in 0..<100 where alive {
            alive = kill(started, 0) == 0
            if alive { try await Task.sleep(for: .milliseconds(10)) }
        }
        #expect(!alive)
    }

    @Test func hasNoPathWhenTheShellFails() throws {
        let sh = try shell("failing", "exit 1")
        #expect(readLoginShellPath(shell: sh) == nil)
    }

    @Test func readsThePathOfTheSystemsShell() {
        #expect(readLoginShellPath(shell: "/bin/sh")?.split(separator: ":").contains("/usr/bin") == true)
    }
}
