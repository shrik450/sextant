import Foundation
import Testing
@testable import RevueCore

extension GitIntegrationTests {
    static let agentRoot = URL(fileURLWithPath: fixture.path + "-agent", isDirectory: true)

    func resolve(_ review: Review, pullRequests: [PullRequest] = []) async throws -> ResolvedReview {
        try await Resolver(git: repo).resolve(review, worktrees: await repo.worktrees(), pullRequests: pullRequests)
    }

    func paths(_ r: ResolvedReview) async throws -> [String] {
        try await r.git.diff(r.target).map(\.path)
    }

    @Test func listsWorktreesAndBranches() async throws {
        #expect(Self.ready)
        let worktrees = await repo.worktrees()
        #expect(worktrees.map(\.name) == ["test-fixture", "test-fixture-agent"])
        #expect(worktrees.map(\.branch) == ["feature/peek", "feature/agent"])
        let branches = await repo.branches(comparedWith: "main")
        let byName = Dictionary(uniqueKeysWithValues: branches.map { ($0.name, $0) })
        #expect(Set(byName.keys) == ["main", "feature/peek", "feature/search", "feature/agent", "origin/main", "origin/feature/remote-only"])
        #expect(byName["feature/peek"]?.ahead == 2 && byName["feature/peek"]?.behind == 0)
        #expect(byName["origin/feature/remote-only"]?.isRemote == true && byName["origin/feature/remote-only"]?.ahead == 1)
        #expect(byName["feature/search"]?.ahead == 0)
    }

    @Test func worktreeReviewsCommitsAndUncommittedWork() async throws {
        #expect(Self.ready)
        let r = try await resolve(Review(subject: .worktree(Self.fixture), base: "main"))
        #expect(r.worktree?.branch == "feature/peek")
        #expect(r.commits.map(\.subject) == ["Add greet()", "Print usage to stderr"])
        #expect(r.mergeBase == (await repo.resolve("main")))
        #expect(try await paths(r) == ["dir with space/file name.txt", "main.go", "notes.md", "scripts/build.py", "src/lib.rs", "web/app.ts"])
    }

    @Test func linkedWorktreeRunsInItsOwnCheckout() async throws {
        #expect(Self.ready)
        let all = try await resolve(Review(subject: .worktree(Self.agentRoot), base: "main"))
        #expect(all.git.root.standardizedFileURL == Self.agentRoot.standardizedFileURL)
        #expect(all.worktree?.branch == "feature/agent")
        #expect(all.commits.map(\.subject) == ["Agent: greet from the agent"])
        #expect(try await paths(all) == ["agent-notes.txt", "main.go", "web/app.ts"])
        let unfinished = try await resolve(Review(subject: .worktree(Self.agentRoot), base: "main", scope: .uncommitted))
        #expect(try await paths(unfinished) == ["agent-notes.txt", "web/app.ts"])
    }

    @Test func branchesReviewSinceTheySplitFromTheBase() async throws {
        #expect(Self.ready)
        let peek = try await resolve(Review(subject: .branch("feature/peek"), base: "main"))
        #expect(try await paths(peek) == ["scripts/build.py", "web/app.ts"])
        let remote = try await resolve(Review(subject: .branch("origin/feature/remote-only"), base: "origin/main"))
        #expect(remote.commits.map(\.subject) == ["Document the remote branch"])
        #expect(try await paths(remote) == ["docs/guide.md"])
        let noBase = try await resolve(Review(subject: .branch("feature/peek")))
        #expect(noBase.target == .commit(try #require(await repo.resolve("feature/peek"))))
        await #expect(throws: GitError.self) { try await resolve(Review(subject: .branch("no/such/branch"))) }
    }

    @Test func commitScopesNarrowABranch() async throws {
        #expect(Self.ready)
        let peek = try await resolve(Review(subject: .branch("feature/peek"), base: "main"))
        let greet = peek.commits[0].oid, usage = peek.commits[1].oid
        let one = try await resolve(Review(subject: .branch("feature/peek"), base: "main", scope: .commits(newest: usage, oldest: usage)))
        #expect(one.target == .commit(usage))
        #expect(try await paths(one) == ["scripts/build.py"])
        let span = try await resolve(Review(subject: .branch("feature/peek"), base: "main", scope: .commits(newest: greet, oldest: usage)))
        #expect(try await paths(span) == ["scripts/build.py", "web/app.ts"])
    }

    @Test func pullRequestsUseTheirBaseAndLocalHead() async throws {
        #expect(Self.ready)
        let head = try #require(await repo.resolve("origin/feature/remote-only"))
        let pr = PullRequest(number: 7, title: "Document it", headRefName: "feature/remote-only", headRefOid: head, baseRefName: "main",
                             isDraft: false, author: .init(login: "ada"), updatedAt: Date())
        let r = try await resolve(Review(subject: .pullRequest(7)), pullRequests: [pr])
        #expect(r.review.base == "origin/main")
        #expect(r.pullRequest?.number == 7)
        #expect(try await paths(r) == ["docs/guide.md"])
        await #expect(throws: GitError.self) { try await resolve(Review(subject: .pullRequest(8)), pullRequests: [pr]) }
    }

    @Test func comparisonsAndSingleCommits() async throws {
        #expect(Self.ready)
        let since = try await resolve(Review(subject: .comparison(from: "feature/agent", to: "feature/peek", sinceAncestor: true)))
        #expect(try await paths(since) == ["scripts/build.py", "web/app.ts"])
        let direct = try await resolve(Review(subject: .comparison(from: "feature/agent", to: "feature/peek", sinceAncestor: false)))
        #expect(try await paths(direct) == ["main.go", "scripts/build.py", "web/app.ts"])
        let one = try await resolve(Review(subject: .commit("feature/peek~1"), scope: .uncommitted))
        #expect(one.review.scope == .everything)
        #expect(try await paths(one) == ["scripts/build.py"])
    }

    @Test func searchesCommitsAcrossBranches() async throws {
        #expect(Self.ready)
        #expect(await repo.searchCommits("AGENT").map(\.subject) == ["Agent: greet from the agent"])
        #expect(await repo.searchCommits("remote branch").map(\.subject) == ["Document the remote branch"])
        let oid = try #require(await repo.resolve("feature/search"))
        #expect(await repo.searchCommits(String(oid.prefix(8))).first?.oid == oid)
    }
}
