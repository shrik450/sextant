import Testing
@testable import SextantCore

@Test func readsPathFromEnvOutput() {
    let output = "HOME=/Users/a\nPATH=/nix/bin:/usr/bin\nSHELL=/bin/fish\n"
    #expect(pathVariable(inEnvironment: output) == "/nix/bin:/usr/bin")
}

@Test func ignoresStartupChatterAndTakesTheLastPath() {
    let output = "Welcome!\nPATH is set up\nPATH=/old\nTERM=dumb\nPATH=/nix/bin:/usr/bin"
    #expect(pathVariable(inEnvironment: output) == "/nix/bin:/usr/bin")
}

@Test func hasNoPathWhenEnvPrintsNone() {
    #expect(pathVariable(inEnvironment: "HOME=/Users/a\n") == nil)
}

@Test func putsTheShellsPathBeforeTheSystemsStub() {
    let path = searchPath(shell: "/opt/homebrew/bin:/Users/a/.nix-profile/bin:/usr/bin", known: ["/Users/a/.nix-profile/bin", "/usr/bin"], inherited: "/usr/bin:/bin")
    #expect(path == "/opt/homebrew/bin:/Users/a/.nix-profile/bin:/usr/bin:/bin")
}

@Test func putsKnownToolDirectoriesBeforeInheritedOnesWithoutAShell() {
    let path = searchPath(shell: nil, known: ["/Users/a/.nix-profile/bin", "/usr/bin"], inherited: "/usr/bin:/bin:/usr/sbin")
    #expect(path == "/Users/a/.nix-profile/bin:/usr/bin:/bin:/usr/sbin")
}
