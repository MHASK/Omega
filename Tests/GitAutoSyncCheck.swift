import Foundation

@main struct GitAutoSyncCheck {
    static func main() throws {
        setbuf(stdout, nil)
        let fm = FileManager.default, git = GitRunner(timeout: 10)
        let temp = fm.temporaryDirectory.appendingPathComponent("OmegaAutoGit-" + UUID().uuidString).resolvingSymlinksInPath()
        try fm.createDirectory(at: temp, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: temp) }
        func run(_ args: [String], _ root: URL) throws -> String { try git.git(args, at: root).text.trimmingCharacters(in: .whitespacesAndNewlines) }
        func put(_ root: URL, _ path: String, _ value: String) throws { try Data(value.utf8).write(to: root.appendingPathComponent(path), options: .atomic) }
        func get(_ root: URL, _ path: String) throws -> String { try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8) }
        func check(_ value: @autoclosure () throws -> Bool, _ text: String) throws { guard try value() else { fatalError(text) }; print("PASS:", text) }
        func changed(_ action: () throws -> Void) throws { do { try action(); fatalError("Changed files must defer apply") } catch is GitChangedDuringSync {} }
        let remote = temp.appendingPathComponent("origin.git"), a = temp.appendingPathComponent("a"), b = temp.appendingPathComponent("b")
        _ = try run(["init", "--bare", "--initial-branch=main", remote.path], temp)
        _ = try run(["clone", remote.path, a.path], temp)
        func configure(_ folder: URL) throws {
            _ = try run(["config", "user.name", "Omega Fixture"], folder); _ = try run(["config", "user.email", "fixture@example.invalid"], folder)
            _ = try run(["remote", "set-url", "origin", "https://example.invalid/team/notes.git"], folder)
            _ = try run(["config", "url.\(remote.path).insteadOf", "https://example.invalid/team/notes.git"], folder)
        }
        try configure(a); try put(a, "Page.md", "# Original\n"); try put(a, "Other.md", "Other\n")
        _ = try git.sync(a, credentials: [])
        _ = try run(["clone", remote.path, b.path], temp); try configure(b)
        try put(a, "Page.md", "# My version\n"); try put(b, "Page.md", "# Incoming version\n"); _ = try git.sync(b, credentials: [])
        var pending: GitSyncSession? = try GitSyncSession(root: a)
        try pending!.fetch(credentials: [])
        var conflicts = try pending!.conflicts()
        try check(conflicts.count == 1 && conflicts[0].mine == Data("# My version\n".utf8) && conflicts[0].incoming == Data("# Incoming version\n".utf8), "review contains exact local and incoming copies")
        try check(try get(a, "Page.md") == "# My version\n", "conflict never inserts markers into the open file")
        try pending!.saveReview(); let work = pending!.workspace!; pending = nil
        let restored = try GitSyncSession(root: a, restoring: true)
        try check(restored.workspace == work && (try restored.conflicts()).count == 1, "conflict review survives process restart without a network request")
        try restored.writeCandidate("Page.md", data: Data("# Reviewed together\n".utf8))
        try restored.apply(); _ = try restored.push(credentials: []); restored.discard()
        _ = try git.sync(b, credentials: [])
        try check(try get(b, "Page.md") == "# Reviewed together\n", "reviewed result reaches the other clone")
        let stable = try run(["rev-parse", "HEAD"], b)
        _ = try git.sync(a, credentials: []); _ = try git.sync(b, credentials: [])
        try check(try run(["rev-parse", "HEAD"], a) == stable && run(["rev-parse", "HEAD"], b) == stable, "idle automatic sync creates no reciprocal empty commits")
        // Simulate a slow fetch. The app's CRDT layer supplies the latest active pair.
        try put(b, "Other.md", "Incoming other\n"); _ = try git.sync(b, credentials: [])
        let concurrent = try GitSyncSession(root: a); try concurrent.fetch(credentials: [])
        try put(a, "Page.md", "# Reviewed together\nTyping during the fetch\n")
        try concurrent.apply(activePaths: ["Page.md"]); _ = try concurrent.push(credentials: []); concurrent.discard()
        try check(try get(a, "Page.md").contains("Typing during") && get(a, "Other.md") == "Incoming other\n", "incoming files apply while the open document keeps newer edits")
        _ = try git.sync(b, credentials: [])
        try check(try get(b, "Page.md").contains("Typing during"), "edits made during fetch are published in the same safe merge")
        // Changes in a closed file can't be overwritten by a stale candidate.
        try put(b, "Other.md", "Incoming again\n"); _ = try git.sync(b, credentials: [])
        let stale = try GitSyncSession(root: a); try stale.fetch(credentials: [])
        try put(a, "Other.md", "Outside edit while fetching\n")
        try changed { try stale.apply() }; stale.discard()
        try check(try get(a, "Other.md") == "Outside edit while fetching\n", "outside edits during sync trigger a safe retry")
        // The new review shows that newer outside edit, not the stale pre-fetch copy.
        let next = try GitSyncSession(root: a); try next.fetch(credentials: [])
        conflicts = try next.conflicts()
        try check(conflicts.first?.mine == Data("Outside edit while fetching\n".utf8), "retry reviews the latest local text")
        try next.writeCandidate("Other.md", data: conflicts[0].mine)
        try next.writeCandidate("Other (incoming).md", data: conflicts[0].incoming)
        try next.apply(); _ = try next.push(credentials: []); next.discard()
        try check(try get(a, "Other (incoming).md") == "Incoming again\n", "keep both preserves both full files")
        // Network failure doesn't undo the durable local commit or an ongoing edit.
        let unavailable = temp.appendingPathComponent("offline.git")
        try fm.moveItem(at: remote, to: unavailable)
        try put(a, "Page.md", "# Offline edit\n")
        do { _ = try git.sync(a, credentials: []); fatalError("Network failure expected") } catch is GitFailure {}
        try check(try run(["show", "HEAD:Page.md"], a) == "# Offline edit", "offline edits remain saved in local Git before retry")
        try fm.moveItem(at: unavailable, to: remote); _ = try git.sync(a, credentials: [])
        // Deletion/modify conflicts are first-class choices, never accidental data loss.
        _ = try git.sync(b, credentials: [])
        try fm.removeItem(at: a.appendingPathComponent("Page.md")); try put(b, "Page.md", "# Teammate kept editing\n"); _ = try git.sync(b, credentials: [])
        let deletion = try GitSyncSession(root: a); try deletion.fetch(credentials: [])
        let deletionReview = try deletion.conflicts().first!
        try check(deletionReview.mine == nil && deletionReview.incoming == Data("# Teammate kept editing\n".utf8), "deletion conflict explicitly preserves incoming work")
        try deletion.writeCandidate("Page.md", data: deletionReview.incoming); try deletion.apply(); _ = try deletion.push(credentials: []); deletion.discard()
        try check(try get(a, "Page.md") == "# Teammate kept editing\n", "incoming choice restores a deleted local file")
        // Real binary bytes survive review and selection without UTF-8 conversion.
        _ = try git.sync(b, credentials: [])
        let mine = Data([0, 255, 254, 10, 128]), incoming = Data([0, 240, 222, 11, 129])
        try mine.write(to: a.appendingPathComponent("Picture.png")); try incoming.write(to: b.appendingPathComponent("Picture.png")); _ = try git.sync(b, credentials: [])
        let binary = try GitSyncSession(root: a); try binary.fetch(credentials: [])
        let binaryReview = try binary.conflicts().first!
        try check(binaryReview.mine == mine && binaryReview.incoming == incoming && !binaryReview.editable, "binary conflict previews retain exact attachment bytes")
        try binary.writeCandidate("Picture.png", data: incoming); try binary.apply(); _ = try binary.push(credentials: []); binary.discard()
        // No hidden scratch worktrees are left after successful/background attempts.
        try check(try run(["worktree", "list", "--porcelain"], a).components(separatedBy: "worktree ").count == 2, "completed sync cleans up the private merge worktree")
        print("Automatic Git synchronization checks passed.")
    }
}
