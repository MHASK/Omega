import AppKit
import SwiftUI

@main struct ChecklistCheck {
    @MainActor static func main() {
        setbuf(stdout, nil); _ = NSApplication.shared; NSApp.setActivationPolicy(.prohibited)
        Task { @MainActor in
            do { try await run(); print("PASS: folder checklists and safe source edits"); exit(0) }
            catch { print("FAIL:", error); exit(1) }
        }
        NSApp.run()
    }
    static func require(_ condition: Bool, _ message: String) throws {
        guard condition else { throw TaskPageError(message) }; print("PASS:", message)
    }
    @MainActor static func wait(_ condition: () -> Bool) async throws {
        for _ in 0..<200 { if condition() { return }; try await Task.sleep(for: .milliseconds(25)) }
        throw TaskPageError("Timed out waiting for checklist")
    }
    @MainActor static func run() async throws {
        let fm = FileManager.default, root = URL(fileURLWithPath: CommandLine.arguments[1]).appendingPathComponent("Studio")
        try fm.createDirectory(at: root.appendingPathComponent("Projects"), withIntermediateDirectories: true)
        let note = root.appendingPathComponent("A thoughtful launch.md"), child = root.appendingPathComponent("Projects/Field notes.md")
        let source = "# A thoughtful launch 👋\r\n\r\n<!-- timeline:start -->\r\n- [ ] **Shape the first idea**\r\n  - [x] Gather a little inspiration\r\n  - [ ] Talk it through\r\n- [ ] Share something worth keeping\r\n<!-- timeline:end -->\r\n\r\n```md\r\n- [ ] Code example\r\n```\r\n\r\n    - [ ] Indented example\r\n"
        let parsed = NoteChecklist.items(in: source)
        try require(parsed.count == 4 && parsed[1].depth == 1 && parsed[1].completed, "nested checks, CRLF, Unicode and code exclusion")
        let changed = try NoteChecklist.toggled(parsed[0], in: source, expected: source)
        try require(changed == source.replacingOccurrences(of: "- [ ] **Shape", with: "- [x] **Shape"), "only the checkbox character changes")
        do { _ = try NoteChecklist.toggled(parsed[0], in: source + "Outside edit", expected: source); throw TaskPageError("Accepted stale checkbox") }
        catch { try require(!error.localizedDescription.contains("Accepted stale"), "stale source is rejected") }
        try require(NoteChecklist.items(in: "---\nexample: |\n  - [ ] Hidden\n---\n<!--\n- [ ] Hidden\n-->\n\n- [X] Real").count == 1, "frontmatter and hidden comments are excluded")
        try source.write(to: note, atomically: true, encoding: .utf8)
        try "# Field notes\n\n- [ ] Find a quiet place\n- [x] Write down a small discovery\n".write(to: child, atomically: true, encoding: .utf8)
        let archive = root.appendingPathComponent("Archived.md")
        try "- [ ] Not active".write(to: archive, atomically: true, encoding: .utf8)
        let notebook = Notebook(recovery: DraftRecovery(directory: root.deletingLastPathComponent().appendingPathComponent("Recovery")))
        notebook.root = root; notebook.notebooks = [root]; notebook.reloadTree(); notebook.select(note)
        notebook.library.archived.insert(archive.path); notebook.showChecklist(in: root)
        let model = FolderChecklistModel(); model.refresh(root, notebook: notebook)
        try await wait { !model.loading }
        try require(model.groups.count == 2 && model.groups.flatMap(\.items).count == 6, "folder view gathers descendants and excludes archives")
        let group = model.groups.first { $0.url == note }!
        model.toggle(group.items[0], group: group, notebook: notebook)
        try await wait { model.busy == nil && model.groups.first { $0.url == note }?.source == changed }
        try require(try String(contentsOf: note, encoding: .utf8) == changed, "folder checkbox saves original note through recovery and undo")
        let childGroup = model.groups.first { $0.url == child }!, external = childGroup.source + "\nClaude kept writing.\n"
        try external.write(to: child, atomically: true, encoding: .utf8)
        model.toggle(childGroup.items[0], group: childGroup, notebook: notebook)
        try await wait { model.busy == nil && model.groups.first { $0.url == child }?.source == external }
        try require(model.message != nil && String(contentsOf: child, encoding: .utf8) == external, "outside edits survive a stale rollup click")
        let tasks = try TaskDocument(markdown: "<!-- folio:tasks -->\n# Work\n\n## Goals\n\n- [ ] A goal\n\n## To do\n\n- [ ] Parent\n  - [ ] Child\n\n## Done\n")
        let taskURL = root.appendingPathComponent("Work.md"); try tasks.markdown.write(to: taskURL, atomically: true, encoding: .utf8)
        model.refresh(root, notebook: notebook); try await wait { model.groups.contains { $0.url == taskURL } }
        let taskGroup = model.groups.first { $0.url == taskURL }!
        try require(taskGroup.items.count == 2, "existing task pages join the list without duplicating goals")
        model.toggle(taskGroup.items[1], group: taskGroup, notebook: notebook)
        try await wait { model.busy == nil }
        let savedTasks = try TaskDocument(markdown: String(contentsOf: taskURL, encoding: .utf8))
        try require(savedTasks.status(of: savedTasks.tasks[0].subtasks[0]) == savedTasks.completedStatus, "task-page children retain valid completion metadata")
        notebook.appearance = "dark"
        let host = NSHostingView(rootView: FolderChecklistView(folder: root, notebook: notebook).preferredColorScheme(.dark))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1050, height: 730), styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = host; window.orderFront(nil)
        try await Task.sleep(for: .seconds(1)); host.layoutSubtreeIfNeeded()
        if let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
            host.cacheDisplay(in: host.bounds, to: bitmap)
            try bitmap.representation(using: .png, properties: [:])?.write(to: root.deletingLastPathComponent().appendingPathComponent("folder-checklists.png"))
        }
        try require(try fm.contentsOfDirectory(atPath: root.path).sorted() == ["A thoughtful launch.md", "Archived.md", "Projects", "Work.md"], "the rollup creates no duplicate task file")
        window.orderOut(nil)
    }
}
