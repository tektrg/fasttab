import Testing
@testable import AgentBar

struct ProjectNameResolverTests {
    @Test func usesLastPathComponent() {
        #expect(ProjectNameResolver.projectName(fromCwd: "/Users/dev/Projects/sample-app") == "sample-app")
        #expect(ProjectNameResolver.projectName(fromCwd: "/Users/dev/Projects/sample-app/") == "sample-app")
        #expect(ProjectNameResolver.projectName(fromCwd: "/Users/dev/Projects/sample-app/src") == "src")
    }

    @Test func worktreeCwdResolvesToItsRepo() {
        #expect(ProjectNameResolver.projectName(fromCwd: "/Users/dev/Projects/sample-app/.claude/worktrees/feature-x") == "sample-app")
        #expect(ProjectNameResolver.projectName(fromCwd: "/Users/dev/Projects/sample-app/.claude/worktrees/feature-x/src/deep") == "sample-app")
    }

    @Test func dotClaudeWithoutWorktreesIsNotAWorktree() {
        #expect(ProjectNameResolver.projectName(fromCwd: "/Users/dev/Projects/sample-app/.claude") == ".claude")
        #expect(ProjectNameResolver.projectName(fromCwd: "/Users/dev/Projects/sample-app/.claude/skills") == "skills")
    }

    @Test func missingOrRootCwdHasNoProject() {
        #expect(ProjectNameResolver.projectName(fromCwd: nil) == nil)
        #expect(ProjectNameResolver.projectName(fromCwd: "") == nil)
        #expect(ProjectNameResolver.projectName(fromCwd: "/") == nil)
    }
}
