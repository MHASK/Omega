import Foundation
import Darwin

@main struct NotebookMigrationCheck {
    static let fm = FileManager.default
    static func write(_ text: String, _ file: URL) throws {
        try fm.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try DraftRecovery.write(text, to: file)
    }
    static func json(_ object: Any, _ file: URL) throws {
        try fm.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try DraftRecovery.write(JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]), to: file)
    }
    static func read(_ file: URL) throws -> String { try String(contentsOf: file, encoding: .utf8) }
    static func fixture(_ root: URL, suite: String) throws -> (NotebookMigration, NotebookMigration.Request) {
        let source = root.appendingPathComponent("Old/Project"), target = root.appendingPathComponent("Documents/Omega/Project")
        let other = root.appendingPathComponent("Old/Other"), support = root.appendingPathComponent("Support")
        let note = source.appendingPathComponent("Now.md")
        let initial = "# Before\n\n[inside](./Folder/Child.md#task-x)\n[other](../Other/Notes.md)\n`[literal](../Other/Notes.md)`\n"
        let draft = initial.replacingOccurrences(of: "Before", with: "After")
        try write(initial, note)
        try write("Child", source.appendingPathComponent("Folder/Child.md"))
        try write("[project](../Project/Now.md)\n[local](./Second.md)", other.appendingPathComponent("Notes.md"))
        try write("Second", other.appendingPathComponent("Second.md"))
        try write("attachment", source.appendingPathComponent("Assets/image.png"))
        try write("hidden content", source.appendingPathComponent(".omega/live/state.json"))
        try write("git object", source.appendingPathComponent(".git/objects/ab/object"))
        try fm.setAttributes([.posixPermissions: 0o444], ofItemAtPath: source.appendingPathComponent(".git/objects/ab/object").path)
        try fm.createDirectory(at: source.appendingPathComponent("Empty"), withIntermediateDirectories: true)
        let recovery = DraftRecovery(directory: support.appendingPathComponent("Recovery"))
        try recovery.checkpoint(draft, original: initial, file: note)
        let history = UndoHistory(file: recovery.directory.appendingPathComponent("History/undo.sqlite"))
        try history.observe(initial, at: note); try history.record(before: initial, after: draft, at: note)
        try json(["favorites": [note.path], "archived": [source.appendingPathComponent("Folder").path], "order": [source.path: [note.path]]], recovery.directory.appendingPathComponent("Library/state.json"))
        try json([["path": source.path, "provider": "GitHub"]], support.appendingPathComponent("Git/notebooks.json"))
        try json([["folder": source.path, "endpoint": "https://example.com", "enabled": true]], support.appendingPathComponent("Collaboration/connections.json"))
        try json(["original": source.appendingPathComponent("Deleted.md").absoluteString, "backup": "file:///saved/file.md", "completed": true], recovery.directory.appendingPathComponent("History/Deleted Notes/a/record.json"))
        let defaults = UserDefaults(suiteName: suite)!
        defaults.set([source.path, other.path], forKey: "notebooks")
        defaults.set(source.path, forKey: "lastFolder"); defaults.set(note.path, forKey: "lastNote")
        defaults.set([note.path], forKey: "recentNotes"); defaults.set([source.path: "sky", other.path: "rose"], forKey: "notebookColors")
        precondition(defaults.synchronize())
        let migration = NotebookMigration(support: support, defaults: defaults)
        let request = NotebookMigration.Request(id: UUID(), source: source.path, destination: target.path, minimumBuild: 137)
        try fm.createDirectory(at: migration.directory, withIntermediateDirectories: true)
        try DraftRecovery.write(JSONEncoder().encode(request), to: migration.pendingFile)
        return (migration, request)
    }
    static func verify(_ migration: NotebookMigration, _ request: NotebookMigration.Request) throws {
        let source = URL(fileURLWithPath: request.source), target = URL(fileURLWithPath: request.destination)
        let other = source.deletingLastPathComponent().appendingPathComponent("Other/Notes.md"), note = target.appendingPathComponent("Now.md")
        precondition(!fm.fileExists(atPath: source.path) && !fm.fileExists(atPath: migration.pendingFile.path))
        let text = try read(note)
        precondition(text.contains("# After") && text.contains("[inside](./Folder/Child.md#task-x)"))
        let outbound = NoteLinks.href(from: note, to: other)
        precondition(text.contains("[other](\(outbound))"))
        precondition(text.contains("`[literal](../Other/Notes.md)`"))
        let inbound = try read(other)
        precondition(inbound.contains("[project](\(NoteLinks.href(from: other, to: note)))") && inbound.contains("[local](./Second.md)"))
        for path in ["Folder/Child.md", "Assets/image.png", ".omega/live/state.json", ".git/objects/ab/object", "Empty"] { precondition(fm.fileExists(atPath: target.appendingPathComponent(path).path)) }
        let copy = migration.directory.appendingPathComponent(request.id.uuidString + "/Notebook/Now.md")
        let backedUpText = try read(copy); precondition(backedUpText.contains("# After"))
        let defaults = migration.defaults
        precondition(defaults.string(forKey: "lastFolder") == target.path && defaults.string(forKey: "lastNote") == note.path)
        precondition(defaults.stringArray(forKey: "recentNotes") == [note.path])
        precondition((defaults.dictionary(forKey: "notebookColors") as? [String: String])?[target.path] == "sky")
        for path in ["Recovery/Library/state.json", "Git/notebooks.json", "Collaboration/connections.json", "Recovery/History/Deleted Notes/a/record.json"] {
            let object = try JSONSerialization.jsonObject(with: Data(contentsOf: migration.support.appendingPathComponent(path)))
            let data = try JSONSerialization.data(withJSONObject: object, options: [.withoutEscapingSlashes])
            let encoded = String(decoding: data, as: UTF8.self)
            precondition(!encoded.contains(source.path) && !encoded.contains(source.absoluteString))
        }
        let history = UndoHistory(file: migration.support.appendingPathComponent("Recovery/History/undo.sqlite"))
        // A link relocation becomes an ordinary outside edit; the pre-move
        // typing history still follows it and can be undone after relaunch.
        try history.observe(text, at: note)
        let undoneLinks = try history.travel(at: note, expected: text, redo: false) { _ in }
        precondition(undoneLinks?.text.contains("# After") == true)
        let undoneTyping = try history.travel(at: note, expected: undoneLinks!.text, redo: false) { _ in }
        precondition(undoneTyping?.text.contains("# Before") == true)
        let beforeRerun = try Data(contentsOf: note)
        try migration.run(build: 138)
        let afterRerun = try Data(contentsOf: note); precondition(afterRerun == beforeRerun)
    }
    static func main() throws {
        if CommandLine.arguments.count > 1 {
            let root = URL(fileURLWithPath: CommandLine.arguments[1]), suite = CommandLine.arguments[2], stop = CommandLine.arguments[3]
            let migration = NotebookMigration(support: root.appendingPathComponent("Support"), defaults: UserDefaults(suiteName: suite)!)
            migration.checkpoint = { stage in if stage == stop { _exit(73) } }
            try migration.run(build: 137); return
        }
        let root = fm.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("OmegaMigration-" + UUID().uuidString)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        for stop in ["normal", "prepared", "moved", "edit-0", "edit-2", "history", "preferences"] {
            let suite = "local.omega.migration-check." + UUID().uuidString
            let (migration, request) = try fixture(root.appendingPathComponent(stop), suite: suite)
            defer { migration.defaults.removePersistentDomain(forName: suite) }
            try migration.run(build: 136)
            precondition(fm.fileExists(atPath: request.source) && !fm.fileExists(atPath: request.destination))
            if stop != "normal" {
                let child = Process(); child.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
                child.arguments = [root.appendingPathComponent(stop).path, suite, stop]
                try child.run(); child.waitUntilExit(); precondition(child.terminationStatus == 73)
                migration.defaults.synchronize()
            }
            try migration.run(build: 137)
            try verify(migration, request)
            print("PASS: next-build gate, complete migration and crash resume at \(stop)")
        }
        for scenario in ["collision", "symlink", "outside-edit"] {
            let suite = "local.omega.migration-check." + UUID().uuidString
            let (migration, request) = try fixture(root.appendingPathComponent(scenario), suite: suite)
            defer { migration.defaults.removePersistentDomain(forName: suite) }
            if scenario == "collision" { try write("keep destination", URL(fileURLWithPath: request.destination).appendingPathComponent("Keep.md")) }
            if scenario == "symlink" { try fm.createSymbolicLink(atPath: request.source + "/link", withDestinationPath: "/tmp") }
            if scenario == "outside-edit" {
                migration.checkpoint = { stage in if stage == "prepared" { try write("new outside edit", URL(fileURLWithPath: request.source).appendingPathComponent("Now.md")) } }
            }
            do { try migration.run(build: 137); fatalError("Unsafe move succeeded") } catch {}
            precondition(fm.fileExists(atPath: request.source))
            if scenario == "collision" { let kept = try read(URL(fileURLWithPath: request.destination).appendingPathComponent("Keep.md")); precondition(kept == "keep destination") }
            if scenario == "outside-edit" {
                let kept = try read(URL(fileURLWithPath: request.source).appendingPathComponent("Now.md")); precondition(kept == "new outside edit")
                migration.checkpoint = nil
                try migration.run(build: 137)
                let moved = try read(URL(fileURLWithPath: request.destination).appendingPathComponent("Now.md")); precondition(moved == kept)
            }
            print("PASS: \(scenario) preserved without overwrite")
        }
        print("All notebook migration checks passed")
    }
}
