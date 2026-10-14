import Foundation

@MainActor func runAssistantTests() {
    let keys = ["notebooks", "notebookColors", "recentNotes", "lastFolder", "lastNote"]
    let preferences = keys.map { ($0, UserDefaults.standard.object(forKey: $0)) }
    defer { for (key, value) in preferences { UserDefaults.standard.set(value, forKey: key) } }
    let base = FileManager.default.temporaryDirectory.appendingPathComponent("Folio-assistant-tests-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: base) }
    do {
        let root = base.appendingPathComponent("Notebook")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let store = Notebook(recovery: DraftRecovery(directory: base.appendingPathComponent("Recovery")))
        store.root = root; store.notebooks = [root]
        let service = AssistantService(store, history: base.appendingPathComponent("History"))
        func call(_ name: String, _ args: [String: Any] = [:], fails: Bool = false, client: String = "Assistant") -> [String: Any] {
            var response: [String: Any]?
            service.handle(["name": name, "arguments": args, "clientName": client]) { response = $0 }
            precondition(response != nil, "Synchronous fixture unexpectedly deferred")
            precondition(response!["isError"] as? Bool == fails, String(describing: response))
            return response!["structuredContent"] as? [String: Any] ?? [:]
        }
        func note(_ result: [String: Any]) -> (String, String) { (result["path"] as! String, result["revision"] as! String) }
        let explicitStatus = "<!-- folio:tasks -->\n# Outside edits\n\n## Goals\n- [ ] Goal\n\n## To do\n- [ ] Parent\n  <!-- folio:task {\"id\":\"parent\",\"status\":\"Done\",\"description\":\"Keep **details**\",\"labels\":[\"Writing\"]} -->\n  - [ ] Child\n    <!-- folio:task {\"id\":\"child\",\"status\":\"In progress\"} -->\n\n## In progress\n\n## Done\n"
        let explicit = try TaskDocument(markdown: explicitStatus)
        precondition(explicit.tasks[0].status == "Done" && explicit.tasks[0].details.status == nil)
        precondition(explicit.tasks[0].details.description == "Keep **details**" && explicit.tasks[0].details.labels == ["Writing"])
        precondition(explicit.tasks[0].subtasks[0].details.status == "In progress")
        let normalizedExplicit = try TaskDocument(markdown: explicit.markdown)
        precondition(normalizedExplicit.tasks[0].status == "Done" && normalizedExplicit.tasks[0].details.id == "parent")
        let (explicitPath, explicitRevision) = note(call("create_note", ["folder": root.path, "name": "Outside edits", "markdown": explicitStatus]))
        _ = call("update_note", ["path": explicitPath, "expected_revision": explicitRevision, "markdown": explicitStatus.replacingOccurrences(of: "\"status\":\"Done\"", with: "\"status\":\"Unknown\"")], fails: true)
        let unchangedExplicit = try String(contentsOfFile: explicitPath, encoding: .utf8)
        precondition(unchangedExplicit == explicitStatus)
        _ = call("create_note", ["folder": root.path, "name": "Invalid tasks", "markdown": explicitStatus + "Unexpected Markdown\n"], fails: true)
        precondition(!FileManager.default.fileExists(atPath: root.appendingPathComponent("Invalid tasks.md").path))
        print("PASS: outside main-task statuses normalize without losing details; malformed MCP task writes leave files untouched")
        let (file, first) = note(call("create_note", ["folder": root.path, "name": "Café 日本語", "markdown": "# Hello 👋\n\nShared thoughts\n"]))
        _ = call("create_note", ["folder": root.path, "name": "Café 日本語", "markdown": "overwrite"], fails: true)
        _ = call("create_note", ["folder": root.path, "name": "../escape", "markdown": "bad"], fails: true)
        _ = call("read_note", ["path": "/etc/hosts"], fails: true)
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("escape.md"), withDestinationURL: URL(fileURLWithPath: "/etc/hosts"))
        _ = call("read_note", ["path": root.appendingPathComponent("escape.md").path], fails: true)
        _ = call("create_note", ["folder": root.path, "name": ".hidden", "markdown": "bad"], fails: true)
        _ = call("list_items", ["path": root.path, "recursive": "yes"], fails: true)
        _ = call("search_notes", ["query": "shared", "extra": true], fails: true)
        let updated = call("update_note", ["path": file, "expected_revision": first, "markdown": "# Updated\n\nNew idea 👋\n"])
        precondition(FileManager.default.fileExists(atPath: updated["history_copy"] as! String))
        _ = call("update_note", ["path": file, "expected_revision": first, "markdown": "stale"], fails: true)
        precondition(call("read_note", ["path": file])["markdown"] as? String == "# Updated\n\nNew idea 👋\n")
        let folder = call("create_folder", ["folder": root.path, "name": "Projects"])["path"] as! String
        let moved = call("move_item", ["path": file, "folder": folder, "expected_revision": updated["revision"]!])
        let renamed = call("rename_item", ["path": moved["path"]!, "name": "Shared note", "expected_revision": moved["revision"]!])
        precondition((call("search_notes", ["query": "idea"])["results"] as! [[String: Any]]).count == 1)
        // Task tools share revision checks, history, and durable local Markdown.
        try store.saveTaskPreferences(TaskPreferences(statuses: ["Backlog", "Review", "Shipped"], completed: "Shipped"))
        let restored = Notebook(recovery: store.recovery)
        precondition(restored.taskPreferences == store.taskPreferences)
        var page = call("create_task_page", ["folder": root.path, "name": "Release", "title": "Launch 👋"])
        let taskPath = page["path"] as! String
        precondition(page["statuses"] as! [String] == ["Backlog", "Review", "Shipped"])
        func taskCall(_ name: String, _ extra: [String: Any] = [:], fails: Bool = false) {
            var args: [String: Any] = ["path": taskPath, "expected_revision": page["revision"]!]
            extra.forEach { args[$0.key] = $0.value }
            let result = call(name, args, fails: fails); if !fails { page = result }
        }
        taskCall("add_task", ["title": "Write copy", "description": "First line\n\n**Details** <stay> 👋", "due_date": "2026-10-20", "labels": ["Launch", "Writing"]])
        let stale = page["revision"]!
        taskCall("add_task", ["parent_task": 0, "title": "Opening", "description": "Child details", "status": "Review"])
        taskCall("update_task", ["parent_task": 0, "task": 0, "completed": true])
        taskCall("add_goal", ["title": "Ship calmly"])
        taskCall("update_goal", ["goal": 0, "title": "Ship calmly 👋", "completed": true])
        taskCall("update_task", ["task": 0, "status": "Review"])
        taskCall("update_task", ["task": 0, "expected_revision": stale, "title": "Stale"], fails: true)
        taskCall("update_task", ["task": 99, "title": "Missing"], fails: true)
        taskCall("update_task", ["task": 0, "status": "Lost"], fails: true)
        taskCall("add_task", ["parent_task": 0, "title": "Bad", "status": "Missing"], fails: true)
        taskCall("configure_task_statuses", ["statuses": ["Backlog", "Shipped"], "completed_status": "Shipped"], fails: true)
        taskCall("configure_task_statuses", ["statuses": ["Backlog", "In review", "Released"], "completed_status": "Released", "rename_from": "Review", "rename_to": "In review"])
        var taskRows = page["tasks"] as! [[String: Any]]
        precondition(taskRows[0]["status"] as? String == "In review")
        precondition((taskRows[0]["subtasks"] as! [[String: Any]])[0]["completed"] as? Bool == true)
        precondition((page["goals"] as! [[String: Any]])[0]["completed"] as? Bool == true)
        taskCall("update_task", ["task": 0, "completed": true])
        taskRows = page["tasks"] as! [[String: Any]]; precondition(taskRows[0]["status"] as? String == "Released")
        taskCall("configure_task_statuses", ["statuses": ["Backlog", "In review", "Done"], "completed_status": "Done"])
        taskRows = page["tasks"] as! [[String: Any]]; precondition(taskRows[0]["status"] as? String == "Done")
        let before = try String(contentsOfFile: taskPath, encoding: .utf8)
        let parsed = try TaskDocument(markdown: before)
        precondition(parsed.tasks[0].details.description == "First line\n\n**Details** <stay> 👋")
        precondition(parsed.tasks[0].subtasks[0].details.description == "Child details")
        precondition(parsed.tasks[0].details.labels == ["Launch", "Writing"])
        let roundtrip = try TaskDocument(markdown: parsed.markdown)
        precondition(roundtrip.tasks[0].details.description == parsed.tasks[0].details.description)
        taskCall("update_task", ["task": 0, "due_date": "2026-02-30"], fails: true)
        taskCall("update_task", ["task": 0, "description": String(repeating: "a", count: 100001)], fails: true)

        taskCall("configure_task_statuses", ["statuses": ["Goals", "Done"], "completed_status": "Done"], fails: true)
        taskCall("configure_task_statuses", ["statuses": [1, 2], "completed_status": "Done"], fails: true)
        taskCall("configure_task_statuses", ["statuses": ["Done", "done"], "completed_status": "Done"], fails: true)
        precondition((try? String(contentsOfFile: taskPath, encoding: .utf8)) == before)
        taskCall("add_task", ["title": "Another parent", "status": "Done"])
        taskCall("move_task", ["reference": "t:0", "parent_reference": "t:1"])
        let nested = try TaskDocument(markdown: String(contentsOfFile: taskPath, encoding: .utf8))
        precondition(nested.tasks.count == 1 && nested.tasks[0].subtasks[0].subtasks.count == 1)
        precondition(nested.tasks[0].subtasks[0].details.description == parsed.tasks[0].details.description)
        precondition(nested.tasks[0].subtasks[0].details.id == parsed.tasks[0].details.id)
        taskCall("move_task", ["reference": "t:0", "parent_reference": "t:0.0.0"], fails: true)
        taskCall("update_task", ["reference": "t:0.0.0", "labels": ["Nested"]])
        taskCall("move_task", ["reference": "t:0.0"])
        taskCall("remove_task", ["reference": "t:0"])
        let promoted = try TaskDocument(markdown: String(contentsOfFile: taskPath, encoding: .utf8))
        precondition(promoted.tasks[0].details.id == parsed.tasks[0].details.id && promoted.tasks[0].subtasks[0].details.labels == ["Nested"])
        print("PASS: MCP moves complete task trees, preserves IDs/metadata, rejects cycles and updates nested items")
        taskCall("update_task", ["task": 0, "labels": [String](), "due_date": ""])
        let cleared = try TaskDocument(markdown: String(contentsOfFile: taskPath, encoding: .utf8)); precondition(cleared.tasks[0].details.labels == nil && cleared.tasks[0].details.due == nil)
        taskCall("set_task_goals", ["reference": "t:0", "goals": ["g:0"]])
        taskCall("set_task_goals", ["reference": "t:0.0", "goals": ["g:0"]])
        var linkedGoal = (page["goals"] as! [[String: Any]])[0]
        precondition((linkedGoal["progress"] as! [String: Int])["total"] == 2)
        precondition(((page["tasks"] as! [[String: Any]])[0]["goal_ids"] as! [String]).count == 1)
        taskCall("update_goal", ["goal": 0, "completed": true], fails: true)
        taskCall("set_task_goals", ["reference": "t:0", "goals": ["g:999"]], fails: true)
        taskCall("set_task_goals", ["reference": "g:0", "goals": ["g:0"]], fails: true)
        taskCall("set_task_goals", ["reference": "t:0", "goals": ["g:0", "g:0"]], fails: true)
        taskCall("set_task_goals", ["reference": "t:0", "goals": ["g:0"], "expected_revision": stale], fails: true)
        taskCall("update_task", ["reference": "t:0", "completed": true])
        taskCall("update_task", ["reference": "t:0.0", "completed": false])
        linkedGoal = (page["goals"] as! [[String: Any]])[0]
        precondition((linkedGoal["progress"] as! [String: Int])["completed"] == 1 && linkedGoal["completed"] as? Bool == false)
        taskCall("update_task", ["reference": "t:0.0", "completed": true])
        precondition((page["goals"] as! [[String: Any]])[0]["completed"] as? Bool == true)
        taskCall("set_task_goals", ["reference": "t:0.0", "goals": [String]()])
        precondition(((page["goals"] as! [[String: Any]])[0]["progress"] as! [String: Int])["total"] == 1)
        let linkedRoundtrip = try TaskDocument(markdown: String(contentsOfFile: taskPath, encoding: .utf8))
        precondition(linkedRoundtrip.goalProgress(linkedRoundtrip.goals[0]).linked.count == 1)
        print("PASS: MCP goal links, derived progress, unlink, invalid/stale reference rejection and durable goal metadata")
        taskCall("remove_task", ["parent_task": 0, "task": 0])
        taskCall("remove_goal", ["goal": 0])
        precondition(((page["tasks"] as! [[String: Any]])[0]["goal_ids"] as! [String]).isEmpty)
        taskCall("remove_task", ["task": 0])
        precondition((page["tasks"] as! [[String: Any]]).isEmpty && (page["goals"] as! [[String: Any]]).isEmpty)
        let copy = page["history_copy"] as! String; precondition(FileManager.default.fileExists(atPath: copy))
        let pinned = call("set_favorite", ["path": taskPath, "favorite": true]); precondition(pinned["favorite"] as? Bool == true)
        let archived = call("set_archived", ["path": taskPath, "expected_revision": page["revision"]!, "archived": true]); precondition(archived["archived"] as? Bool == true)
        _ = call("set_archived", ["path": taskPath, "expected_revision": page["revision"]!, "archived": false])
        let reread = call("read_task_page", ["path": taskPath]); precondition(reread["title"] as? String == "Launch 👋")
        // Settings update the selected page without dropping tasks, reject stale scope.
        store.select(URL(fileURLWithPath: taskPath))
        let prior = TaskPreferences(statuses: ["Backlog", "In review", "Done"], completed: "Done")
        var settingsResult: String? = "Not called"
        store.configureCurrentTasks(TaskPreferences(statuses: ["Planned", "Doing", "Done"], completed: "Done"), at: URL(fileURLWithPath: taskPath), expected: prior, renames: ["Backlog": "Planned", "In review": "Doing"]) { settingsResult = $0 }
        precondition(settingsResult == nil && store.text.contains("## Planned"))
        store.configureCurrentTasks(prior, at: URL(fileURLWithPath: taskPath), expected: prior, renames: [:]) { settingsResult = $0 }
        precondition(settingsResult != nil && store.text.contains("## Planned"))
        let orderedRoot = root.appendingPathComponent("Ordering")
        try FileManager.default.createDirectory(at: orderedRoot, withIntermediateDirectories: true)
        for name in ["A", "B", "C"] { try name.write(to: orderedRoot.appendingPathComponent(name + ".md"), atomically: true, encoding: .utf8) }
        let a = orderedRoot.appendingPathComponent("A.md"), c = orderedRoot.appendingPathComponent("C.md")
        try store.reorderItem(c, beside: a, after: false)
        let orderingReopened = Notebook(recovery: store.recovery)
        let orderedScan = try NoteFiles.scan(orderedRoot)
        precondition(orderingReopened.orderedEntries(orderedScan).map(\.name) == ["C", "A", "B"])
        let beforeReorder = try String(contentsOf: a, encoding: .utf8)
        precondition(beforeReorder == "A")
        store.reloadTree(); _ = try store.renameItem(c, to: "First")
        let renamedScan = try NoteFiles.scan(orderedRoot)
        precondition(store.orderedEntries(renamedScan).map(\.name) == ["First", "A", "B"])
        print("PASS: folder ordering persists across restart and rename without altering files")
        print("PASS: MCP tasks/subtasks/goals CRUD, custom statuses, completion migration, stale revisions, history, archive/favorites, persistent settings and stale-settings protection")
        let visible = URL(fileURLWithPath: renamed["path"] as! String)
        store.select(visible); store.edit("# In progress\n\nHuman keystrokes")
        let latest = call("read_note", ["path": visible.path])
        precondition(latest["markdown"] as? String == store.text)
        _ = call("rename_item", ["path": visible.path, "name": "Changed", "expected_revision": latest["revision"]!], fails: true)
        _ = call("update_note", ["path": visible.path, "expected_revision": latest["revision"]!, "markdown": "# Together\n"], client: "claude-code")
        precondition(store.text == "# Together\n")
        precondition(store.updateActivity?.message == "Updated by Claude")
        precondition(FolioMCP.displayName("codex-mcp-client") == "Codex")
        precondition(FolioMCP.displayName("unknown\nClaude’s friend") == "Claude")
        precondition(FolioMCP.displayName(nil) == "Assistant")
        // A stale assistant cannot override a dirty human draft or an outside edit.
        store.edit("# Human again\n")
        _ = call("update_note", ["path": visible.path, "expected_revision": latest["revision"]!, "markdown": "wrong"], fails: true)
        precondition(store.text == "# Human again\n")
        store.edit("# Draft\n")
        try "# Outside\n".write(to: visible, atomically: true, encoding: .utf8)
        _ = call("get_context", fails: true)
        precondition(store.text == "# Draft\n")
        store.dirty = false // Fixture teardown; never save the divergent draft.
        let newBook = call("create_notebook", ["beside": root.path, "name": "Other book"])
        precondition(store.roots.count == 2 && newBook["kind"] as? String == "folder")
        _ = call("create_notebook", ["beside": root.path, "name": "Other book"], fails: true)
        let watched = root.appendingPathComponent("Watched.md")
        try "# Watch\n".write(to: watched, atomically: true, encoding: .utf8)
        store.select(watched)
        for (index, atomic) in [true, true, false].enumerated() {
            let expected = "# Outside update \(index)\n"
            let started = Date()
            try expected.write(to: watched, atomically: atomic, encoding: .utf8)
            while store.text != expected && Date().timeIntervalSince(started) < 1 {
                RunLoop.main.run(until: Date().addingTimeInterval(0.015))
            }
            precondition(store.text == expected, "Filesystem notification did not refresh the open note within one second")
            precondition(store.updateActivity?.message == "Updated externally")
        }
        store.select(visible)
        precondition(store.updateActivity == nil, "Activity leaked to another note")
        print("PASS: named MCP update activity, sub-second external file updates, repeated atomic replacement, in-place writes, and note-switch activity cleanup")
        print("PASS: assistant scope, symlink/hidden-path rejection, schema validation, Unicode CRUD, version conflicts, history, shared drafts, collision protection, folders, rename/move, search, notebooks")
    } catch { fputs("Assistant tests failed: \(error)\n", stderr); exit(1) }
}
