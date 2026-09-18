import Foundation

/// Turns an agent's working directory into the project name people recognise.
enum ProjectNameResolver {
    private static let worktreeMarkerComponents = [".claude", "worktrees"]

    /// Last path component, except inside a Claude worktree
    /// (`<repo>/.claude/worktrees/<name>[/...]`), where it is `<repo>`.
    static func projectName(fromCwd cwd: String?) -> String? {
        guard let cwd else { return nil }
        let components = cwd.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard let last = components.last else { return nil }
        if let repoName = repoNameOfEnclosingWorktree(in: components) { return repoName }
        return last
    }

    private static func repoNameOfEnclosingWorktree(in components: [String]) -> String? {
        let markerLength = worktreeMarkerComponents.count
        guard components.count > markerLength else { return nil }
        for markerStart in 1...(components.count - markerLength) {
            let markerEnd = markerStart + markerLength
            if Array(components[markerStart..<markerEnd]) == worktreeMarkerComponents {
                return components[markerStart - 1]
            }
        }
        return nil
    }
}
