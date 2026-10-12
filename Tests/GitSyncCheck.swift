import Foundation

@main struct GitSyncCheck {
    static func main() throws {
        let fm = FileManager.default, git = GitRunner(timeout: 20)
        let temp = fm.temporaryDirectory.appendingPathComponent("OmegaGitTests-" + UUID().uuidString).resolvingSymlinksInPath()
        try fm.createDirectory(at: temp, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: temp) }
        func expect(_ value: @autoclosure () throws -> Bool, _ message: String) throws {
            guard try value() else { fatalError(message) }
        }
        func rejected(_ message: String, _ action: () throws -> Void) throws {
            do { try action(); fatalError(message) } catch is GitFailure { }
        }
        func run(_ args: [String], _ root: URL) throws -> String { try git.git(args, at: root).text.trimmingCharacters(in: .whitespacesAndNewlines) }
        func write(_ root: URL, _ path: String, _ text: String) throws { try Data(text.utf8).write(to: root.appendingPathComponent(path)) }
        func content(_ root: URL, _ path: String) throws -> String { try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8) }
        let remote = temp.appendingPathComponent("remote.git")
        _ = try run(["init", "--bare", "--initial-branch=main", remote.path], temp)
        let first = temp.appendingPathComponent("one"), second = temp.appendingPathComponent("two")
        _ = try run(["clone", remote.path, first.path], temp)
        func configure(_ folder: URL) throws {
            _ = try run(["config", "user.name", "Omega Test"], folder)
            _ = try run(["config", "user.email", "omega-test@example.invalid"], folder)
            _ = try run(["remote", "set-url", "origin", "https://example.invalid/team/notes.git"], folder)
            _ = try run(["config", "url.\(remote.path).insteadOf", "https://example.invalid/team/notes.git"], folder)
        }
        try configure(first)
        try write(first, "Welcome.md", "# Welcome\n\nSafe local notes.\n")
        try write(first, ".env", "PRIVATE=do-not-share")
        try write(first, "tool.sh", "never-commit-this")
        _ = try git.sync(first, credentials: [])
        try expect(try run(["ls-tree", "--name-only", "HEAD"], first) == "Welcome.md", "Only notes should be committed")
        try expect(try run(["diff", "--cached", "--name-only"], first).isEmpty, "Index should match committed state")
        _ = try run(["clone", remote.path, second.path], temp); try configure(second)
        try expect(try content(second, "Welcome.md").contains("Safe local"), "Initial push should survive clone")
        // Untracked non-note files are never committed. Remove fixture files to permit incoming merges.
        try fm.removeItem(at: first.appendingPathComponent(".env")); try fm.removeItem(at: first.appendingPathComponent("tool.sh"))
        try write(second, "Other.md", "# A teammate's note\n")
        _ = try git.sync(second, credentials: [])
        _ = try git.sync(first, credentials: [])
        try expect(try content(first, "Other.md") == "# A teammate's note\n", "Fast-forward pulls should update notes")
        // Independent edits on both machines merge, rather than requiring a manual rebase.
        try write(first, "One.md", "First collaborator\n")
        try write(second, "Two.md", "Second collaborator\n")
        _ = try git.sync(second, credentials: [])
        _ = try git.sync(first, credentials: [])
        _ = try git.sync(second, credentials: [])
        try expect(try content(first, "Two.md") == "Second collaborator\n", "Concurrent independent edits should merge")
        try expect(try content(second, "One.md") == "First collaborator\n", "Merged notes should reach both copies")
        try expect(try run(["status", "--porcelain"], first).isEmpty, "Merge must leave a clean index")
        // A real conflict stays entirely in the temporary worktree; live notes are never marked up.
        try write(first, "Welcome.md", "# First edit\n")
        try write(second, "Welcome.md", "# Second edit\n")
        _ = try git.sync(second, credentials: [])
        try rejected("Overlapping edits must stop for resolution") { _ = try git.sync(first, credentials: []) }
        try expect(try content(first, "Welcome.md") == "# First edit\n", "Conflicts must preserve local text")
        try expect(try run(["show", "HEAD:Welcome.md"], first) == "# First edit", "Conflicting local edits must be committed safely")
        try expect(!fm.fileExists(atPath: first.appendingPathComponent(".git/MERGE_HEAD").path), "Never leave live repository in a merge")
        try expect(try run(["worktree", "list", "--porcelain"], first).components(separatedBy: "worktree ").count == 2, "Temporary worktree should be cleaned")
        // Pre-existing staged edits must remain byte-for-byte intact.
        try write(first, "One.md", "Staged but not working copy\n")
        _ = try run(["add", "One.md"], first)
        try write(first, "One.md", "Working copy differs\n")
        let staged = try run(["show", ":One.md"], first)
        try rejected("Staged work should block sync") { _ = try git.sync(first, credentials: []) }
        try expect(try run(["show", ":One.md"], first) == staged, "Preserve unique staged content")
        try expect(try content(first, "One.md") == "Working copy differs\n", "Preserve unique working content")
        try rejected("Subfolders should not sync their parent repository") { _ = try git.inspect(first.appendingPathComponent(".git")) }
        for invalid in ["http://github.com/me/notes", "https://token@github.com/me/notes", "https://github.com/me/notes?token=x", "https://github.com/me/../notes", "ssh://git@github.com/me/notes", "https://github.com/owner"] {
            try rejected("Reject invalid remote \(invalid)") { _ = try GitRemote(invalid) }
        }
        try expect(try GitRemote("https://gitlab.com/group/subgroup/notes").project == "group/subgroup/notes", "GitLab nested namespaces work")
        try expect(!GitRunner.isNotePath(".env") && !GitRunner.isNotePath("private/.secret.md") && !GitRunner.isNotePath("../outside.md"), "Hidden and traversal paths excluded")
        try expect(GitRunner.isNotePath("Project/Tasks.md") && GitRunner.isNotePath("images/photo.png"), "Tasks and attachments are supported")
        print("Git checks passed: notes-only commits, two-copy sync, safe merges, conflict preservation, staged-content protection, remote validation.")
    }
}
