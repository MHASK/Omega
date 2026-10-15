import AppKit
import SwiftUI
import WebKit

@main struct FolderTasksWebCheck {
    @MainActor static func main() {
        setbuf(stdout, nil); _ = NSApplication.shared; NSApp.setActivationPolicy(.prohibited)
        Task { @MainActor in
            do { try await run(); print("PASS: folder task WebKit integration"); exit(0) }
            catch { print("FAIL:", error); exit(1) }
        }; NSApp.run()
    }
    static func require(_ condition: Bool, _ message: String) throws { guard condition else { throw TaskPageError(message) }; print("PASS:", message) }
    @MainActor static func web(_ root: NSView) -> WKWebView? { if let v = root as? WKWebView { return v }; for child in root.subviews { if let v = web(child) { return v } }; return nil }
    @MainActor static func js(_ view: WKWebView, _ code: String) async throws -> Any { try await view.evaluateJavaScript(code) }
    @MainActor static func wait(_ view: WKWebView, _ expression: String) async throws {
        for _ in 0..<240 { if (try? await js(view, expression)) as? Bool == true { return }; try await Task.sleep(for: .milliseconds(40)) }
        let body = (try? await js(view, "document.body.innerText")) ?? ""
        throw TaskPageError("Timed out: " + expression + "\n" + String(describing: body))
    }
    @MainActor static func run() async throws {
        let root = URL(fileURLWithPath: CommandLine.arguments[1]).appendingPathComponent("Studio")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let taskURL = root.appendingPathComponent("The next chapter.md"), noteURL = root.appendingPathComponent("Field notes.md")
        try """
        <!-- folio:tasks -->
        # The next chapter
        ## Goals
        - [ ] Make something worth keeping
          <!-- folio:task {"id":"goal"} -->
        ## To do
        - [ ] Shape the first idea
          <!-- folio:task {"id":"parent","labels":["design"],"description":"A little room to think."} -->
          - [x] Gather inspiration
            <!-- folio:task {"id":"child"} -->
        - [ ] Invite a friend
          <!-- folio:task {"id":"invite","labels":["people"]} -->
        ## In progress
        - [ ] Bring the useful bits together
          <!-- folio:task {"id":"progress","labels":["writing"]} -->
        ## Done
        - [x] Find a quiet place
          <!-- folio:task {"id":"done"} -->
        """.write(to: taskURL, atomically: true, encoding: .utf8)
        let note = "# Field notes\n\nThese words stay exactly where they are.\n\n- [ ] Write down one small discovery\n- [x] Leave a little space\n\n| Name | Value |\n| --- | --- |\n| Keep | exact |\n"
        try note.write(to: noteURL, atomically: true, encoding: .utf8)
        let notebook = Notebook(recovery: DraftRecovery(directory: root.deletingLastPathComponent().appendingPathComponent("Recovery")))
        notebook.root = root; notebook.notebooks = [root]; notebook.reloadTree(); notebook.checklistFolder = root; notebook.appearance = "dark"; notebook.zoom = 1
        let host = NSHostingView(rootView: FolderChecklistView(folder: root, notebook: notebook).preferredColorScheme(.dark))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1180, height: 770), styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = host; window.orderFront(nil); host.layoutSubtreeIfNeeded()
        guard let view = web(host) else { throw TaskPageError("No folder WebKit view") }
        try await wait(view, "!!window.folderTasks && document.querySelectorAll('.task-list-row').length===6")
        try require(try await js(view, "document.querySelectorAll('.task-list-row>.folder-source').length") as? Int == 6, "every list row shows its source page")
        try require(try await js(view, "document.querySelector('.tasks-title').tagName==='SPAN' && document.querySelector('.tasks-header').getBoundingClientRect().top===0") as? Bool == true, "folder title uses the same full-bleed task header")
        _ = try await js(view, "document.querySelector('[aria-label=\"Board view\"]').click()")
        try await wait(view, "document.querySelectorAll('.board .task-card').length===7")
        try require(try await js(view, "document.querySelectorAll('.board .task-card>.folder-source').length") as? Int == 7, "board cards and nested subtasks show source pages")
        let board = try await view.takeSnapshot(configuration: nil)
        if let data = board.tiffRepresentation, let bitmap = NSBitmapImageRep(data: data) { try bitmap.representation(using: .png, properties: [:])?.write(to: root.deletingLastPathComponent().appendingPathComponent("folder-board.png")) }
        _ = try await js(view, "document.querySelector('[aria-label=\"Open task: Shape the first idea\"]').click();var s=document.querySelector('[aria-label=\"Task status\"]');s.value='1';s.dispatchEvent(new Event('change',{bubbles:true}));true")
        try await wait(view, "!window.folderTasks.snapshot().pending && !window.folderTasks.snapshot().error")
        let moved = try TaskDocument(markdown: String(contentsOf: taskURL, encoding: .utf8))
        try require(moved.tasks.first { $0.details.id == "parent" }?.status == "In progress", "detail status writes the source task page")
        try require(try String(contentsOf: noteURL, encoding: .utf8) == note, "editing a task page leaves notes byte-for-byte unchanged")
        _ = try await js(view, "document.querySelector('[aria-label=\"Back to tasks\"]').click();document.querySelector('[aria-label=\"Open task: Write down one small discovery\"]').click();var s=document.querySelector('[aria-label=\"Task status\"]');s.value='1';s.dispatchEvent(new Event('change',{bubbles:true}));true")
        try await wait(view, "!window.folderTasks.snapshot().pending && !window.folderTasks.snapshot().error")
        let noteAfter = try String(contentsOf: noteURL, encoding: .utf8)
        let inline = try InlineTaskDocument(noteAfter, preferences: TaskPreferences())
        try require(inline.document.tasks[0].status == "In progress" && noteAfter.contains("| Keep | exact |"), "inline tasks receive full status details while their table survives")
        _ = try await js(view, "document.querySelector('[aria-label=\"Choose goals\"]').click();document.querySelector('[aria-label=\"Link goal: Make something worth keeping\"]').click();document.querySelector('[aria-label=\"Choose goals\"]').click();true")
        try await wait(view, "!window.folderTasks.snapshot().pending && !window.folderTasks.snapshot().error")
        let linked = try FolderTaskSource(url: noteURL, text: String(contentsOf: noteURL, encoding: .utf8), preferences: TaskPreferences())
        try require(linked.document.tasks[0].details.extra["omegaGoalSources"] != nil, "a note task can link a goal from a different page")
        _ = try await js(view, "document.querySelector('[aria-label=\"Back to tasks\"]').click();document.querySelector('[aria-label=\"Manage goals\"]').click();document.querySelector('[aria-label=\"Open goal: Make something worth keeping\"]').click();true")
        try require(try await js(view, "document.querySelectorAll('.goal-linked-row').length===1 && document.querySelector('.goal-linked-row .folder-source').textContent.includes('Field notes')") as? Bool == true, "goal details show linked work and its source page")
        let goal = try await view.takeSnapshot(configuration: nil)
        if let data = goal.tiffRepresentation, let bitmap = NSBitmapImageRep(data: data) { try bitmap.representation(using: .png, properties: [:])?.write(to: root.deletingLastPathComponent().appendingPathComponent("folder-goal.png")) }
        _ = try await js(view, "document.querySelector('[aria-label=\"Back to tasks\"]').click();document.querySelector('[aria-label=\"List view\"]').click();var input=document.querySelector('[aria-label=\"Find folder tasks\"]');input.value='discovery';input.dispatchEvent(new Event('input'));input.blur();true")
        try require(try await js(view, "[...document.querySelectorAll('.task-list-row')].filter(r=>!r.hidden).length===1") as? Bool == true, "folder search filters across source pages")
        _ = try await js(view, "var input=document.querySelector('[aria-label=\"Find folder tasks\"]');input.value='';input.dispatchEvent(new Event('input'));true")
        let list = try await view.takeSnapshot(configuration: nil)
        if let data = list.tiffRepresentation, let bitmap = NSBitmapImageRep(data: data) { try bitmap.representation(using: .png, properties: [:])?.write(to: root.deletingLastPathComponent().appendingPathComponent("folder-list.png")) }
        window.setContentSize(NSSize(width: 480, height: 770));try await Task.sleep(for: .milliseconds(200))
        try require(try await js(view, "document.documentElement.scrollWidth<=innerWidth") as? Bool == true, "compact folder layout does not overflow horizontally")
        let narrow = try await view.takeSnapshot(configuration: nil)
        if let data = narrow.tiffRepresentation, let bitmap = NSBitmapImageRep(data: data) { try bitmap.representation(using: .png, properties: [:])?.write(to: root.deletingLastPathComponent().appendingPathComponent("folder-narrow.png")) }
        window.setContentSize(NSSize(width:1180,height:770))
        // Real composer creation selects the source before the first keystroke.
        _ = try await js(view, "document.querySelector('[aria-label=\"Add\"]').click();document.querySelector('[aria-label=\"Add task\"]').click();var dest=document.querySelector('[aria-label=\"Source page\"]');dest.value=[...dest.options].find(o=>o.textContent==='Field notes').value;dest.dispatchEvent(new Event('change'));var title=document.querySelector('[aria-label=\"Title\"]');title.value='A task created from the folder';title.dispatchEvent(new Event('input',{bubbles:true}));true")
        try await wait(view, "!window.folderTasks.snapshot().pending && !window.folderTasks.snapshot().error")
        _ = try await js(view, "document.querySelector('[aria-label=\"Create task\"]').click();true")
        try await wait(view, "!window.folderTasks.snapshot().pending && !window.folderTasks.snapshot().error")
        try require(try String(contentsOf: noteURL, encoding: .utf8).contains("A task created from the folder"), "the composer saves new tasks into the chosen source note")
        _ = try await js(view, "document.querySelector('[aria-label=\"Open task: A task created from the folder\"]').click();var s=document.querySelector('[aria-label=\"Task status\"]');s.value='2';s.dispatchEvent(new Event('change',{bubbles:true}));true")
        try await wait(view, "!window.folderTasks.snapshot().pending && !window.folderTasks.snapshot().error")
        notebook.folderTasksEditor?.command("undo")
        try await wait(view, "!window.folderTasks.snapshot().pending && !window.folderTasks.snapshot().error && document.querySelector('[aria-label=\"Task status\"]').value==='0'")
        let undone = try InlineTaskDocument(String(contentsOf: noteURL, encoding: .utf8), preferences: TaskPreferences())
        try require(undone.document.tasks.first { $0.title == "A task created from the folder" }?.status == "To do", "the native Undo menu restores the source file’s prior status")
        _ = try await js(view, "document.querySelector('[aria-label=\"Back to tasks\"]').click();true")
        // Labels created on inline tasks participate in the same settings catalog.
        let labeledSource = try String(contentsOf: noteURL, encoding: .utf8).replacingOccurrences(of: "\"status\":\"In progress\"", with: "\"status\":\"In progress\",\"labels\":[\"research\"]")
        try labeledSource.write(to: noteURL, atomically: true, encoding: .utf8)
        let pages = try TaskLabelCatalog.pages(in: [root])
        try require(TaskLabelCatalog.labels(in: pages).contains { $0.name == "research" }, "settings discover labels on inline tasks")
        var labelPage = pages.first { $0.file == noteURL }!
        labelPage.document.replaceLabel("research", with: "discovery")
        let renamed = try labelPage.rendered()
        try require(renamed.contains("discovery") && renamed.contains("| Keep | exact |"), "label renaming preserves the note and its table")
        // Hold a real text field to defer refresh, then race an outside writer.
        _ = try await js(view, "document.querySelector('[aria-label=\"Open task: Write down one small discovery\"]').click();document.querySelector('[aria-label=\"Task title\"]').focus();true")
        let external = try String(contentsOf: noteURL, encoding: .utf8) + "\nAn outside editor added this.\n"
        try external.write(to: noteURL, atomically: true, encoding: .utf8)
        _ = try await js(view, "var s=document.querySelector('[aria-label=\"Task status\"]');s.value='2';s.dispatchEvent(new Event('change',{bubbles:true}));true")
        try await wait(view, "!!window.folderTasks.snapshot().error")
        try require(try String(contentsOf: noteURL, encoding: .utf8) == external, "stale folder actions never overwrite an outside edit")
        try require(try await js(view, "document.querySelector('.folder-notice').textContent.includes('Reload') && document.querySelector('[aria-label=\"Task title\"]').disabled") as? Bool == true, "a save conflict preserves the proposal and stops further writes")
        _ = try await js(view, "document.activeElement.blur();document.querySelector('[aria-label=\"Reload folder tasks\"]').click();true")
        try await wait(view, "!window.folderTasks.snapshot().error && !window.folderTasks.snapshot().pending && !document.querySelector('.folder-notice')")
        try require(try FileManager.default.contentsOfDirectory(atPath: root.path).count == 2, "folder view creates no duplicate tasks file")
        window.orderOut(nil)
    }
}
