import Foundation

@MainActor func runWorkCoordinationTests() throws {
    let base = FileManager.default.temporaryDirectory.appendingPathComponent("Omega-work-tests-" + UUID().uuidString), root = base.appendingPathComponent("Notes")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: base) }
    let store = Notebook(recovery: DraftRecovery(directory: base.appendingPathComponent("Recovery"))); store.root = root; store.notebooks = [root]
    let service = AssistantService(store, history: base.appendingPathComponent("History"))
    func call(_ name: String, _ args: [String: Any] = [:], fails: Bool = false) -> [String: Any] {
        var response: [String: Any]?
        service.handle(["name": name, "arguments": args]) { response = $0 }
        precondition(response != nil && response!["isError"] as? Bool == fails, "\(name): \(String(describing: response))")
        return response!["structuredContent"] as? [String: Any] ?? [:]
    }
    let a = call("create_task_page", ["folder": root.path, "name": "Plan"]), path = a["path"] as! String
    var page = call("add_task", ["path": path, "expected_revision": a["revision"]!, "title": "Build the foundation"])
    let firstID = (page["tasks"] as! [[String: Any]])[0]["id"] as! String
    page = call("add_task", ["path": path, "expected_revision": page["revision"]!, "title": "Ship the release"])
    let secondID = (page["tasks"] as! [[String: Any]])[1]["id"] as! String
    page = call("set_task_dependencies", ["path": path, "expected_revision": page["revision"]!, "reference": "t:1", "dependencies": ["Plan.md#" + firstID]])
    var queue = call("read_work_queue", ["path": root.path, "state": "ready"])["tasks"] as! [[String: Any]]
    precondition(queue.count == 1 && queue[0]["id"] as? String == firstID)
    _ = call("set_task_dependencies", ["path": path, "expected_revision": page["revision"]!, "reference": "t:0", "dependencies": ["Plan.md#" + secondID]], fails: true)
    _ = call("set_task_dependencies", ["path": path, "expected_revision": page["revision"]!, "reference": "t:0", "dependencies": ["Plan.md#missing"]], fails: true)
    let stale = page["revision"]!
    page = call("claim_task", ["path": path, "expected_revision": stale, "reference": "t:0", "owner": "Claude / foundation"])
    let receipt = page["claim_token"] as! String
    _ = call("claim_task", ["path": path, "expected_revision": stale, "reference": "t:0", "owner": "Codex / duplicate"], fails: true)
    _ = call("claim_task", ["path": path, "expected_revision": page["revision"]!, "reference": "t:0", "owner": "Codex / duplicate"], fails: true)
    _ = call("configure_task_work", ["path": path, "expected_revision": page["revision"]!, "reference": "t:0", "assignee": "Wrong owner"], fails: true)
    _ = call("update_task", ["path": path, "expected_revision": page["revision"]!, "reference": "t:0", "completed": true], fails: true)
    _ = call("release_task", ["path": path, "expected_revision": page["revision"]!, "reference": "t:0", "claim_token": "wrong"], fails: true)
    page = call("configure_task_work", ["path": path, "expected_revision": page["revision"]!, "reference": "t:0", "claim_token": receipt, "branch": "feature/foundation", "session": "session-123"])
    page = call("handoff_task", ["path": path, "expected_revision": page["revision"]!, "reference": "t:0", "claim_token": receipt, "handoff": "Implemented. Tests passed. Review migration before merging.", "pull_request": "https://example.com/pull/1"])
    queue = call("read_work_queue", ["path": root.path, "state": "review"])["tasks"] as! [[String: Any]]
    precondition(queue.count == 1 && (page["tasks"] as! [[String: Any]])[0]["completed"] as? Bool == false)
    page = call("update_task", ["path": path, "expected_revision": page["revision"]!, "reference": "t:0", "completed": true])
    queue = call("read_work_queue", ["path": root.path, "state": "ready"])["tasks"] as! [[String: Any]]
    precondition(queue.count == 1 && queue[0]["id"] as? String == secondID)
    let restarted = try TaskDocument(markdown: String(contentsOfFile: path, encoding: .utf8))
    precondition(restarted.references.contains { TaskCoordination.text($0.details, "omegaBranch") == "feature/foundation" && TaskCoordination.text($0.details, "omegaHandoff").contains("Tests passed") })
    print("PASS: ready dependencies, loop/missing-target rejection, exclusive claim competition, stale revisions, ownership receipts, durable handoffs and review before completion")

    let note = call("create_note", ["folder": root.path, "name": "Field", "markdown": "# Field\n\nKeep **this** paragraph.\n\n- [ ] Check the release\n\n| Keep | Table |\n| --- | --- |\n| Exact | Cells |\n"])
    let inlinePath = note["path"] as! String
    var inline = call("ensure_task_identity", ["path": inlinePath, "expected_revision": note["revision"]!, "reference": "t:0"])
    let identityText = try String(contentsOfFile: inlinePath, encoding: .utf8)
    precondition(identityText.contains("<!-- omega-task:") && identityText.contains(inline["item_id"] as! String), "ensure_task_identity must write an actual persistent ID")
    inline = call("set_task_dependencies", ["path": inlinePath, "expected_revision": inline["revision"]!, "reference": "t:0", "dependencies": ["Plan.md#" + secondID]])
    let blocked = call("read_work_queue", ["path": root.path, "state": "blocked"])["tasks"] as! [[String: Any]]
    precondition(blocked.contains { $0["path"] as? String == inlinePath })
    let inlineSaved = try String(contentsOfFile: inlinePath, encoding: .utf8)
    precondition(inlineSaved.contains("| Keep | Table |\n| --- | --- |\n| Exact | Cells |"))
    let (snapshot, warnings) = try service.workSnapshot(root)
    precondition(warnings.isEmpty)
    let inlineVirtual = snapshot.document.references.first { $0.title == "Check the release" }!
    let secondVirtual = snapshot.document.references.first { $0.title == "Ship the release" }!
    var cyclic = snapshot.document
    try cyclic.updateDetails(secondVirtual.reference) { $0.extra["omegaDependencies"] = .array([.object(["id": .string(inlineVirtual.details.id!)])]) }
    do { _ = try snapshot.edits(cyclic); preconditionFailure("Cross-page cycle accepted") } catch {}
    let reopened = try FolderTaskSnapshot(folder: root, sources: snapshot.sources, preferences: TaskPreferences())
    let noOpEdits = try reopened.edits(reopened.document)
    precondition(noOpEdits.isEmpty)
    let legacy = call("create_note", ["folder": root.path, "name": "Legacy", "markdown": "# Existing note\n\n- [ ] Read the checklist\n"])
    let (legacySnapshot, _) = try service.workSnapshot(root)
    let legacyTarget = legacySnapshot.document.references.first { $0.title == "Read the checklist" }!
    let legacyConsumer = legacySnapshot.document.references.first { $0.title == "Check the release" }!
    var linkLegacy = legacySnapshot.document
    try linkLegacy.updateDetails(legacyConsumer.reference) { $0.extra["omegaDependencies"] = .array([.object(["id": .string(legacyTarget.details.id!)])]) }
    let legacyEdits = try legacySnapshot.edits(linkLegacy)
    precondition(legacyEdits.count == 2, "Linking a legacy target must save its identity as well as the dependency")
    for edit in legacyEdits { try Data(edit.after.utf8).write(to: edit.url, options: .atomic) }
    let legacyPage = call("read_task_page", ["path": legacy["path"]!])
    precondition((legacyPage["tasks"] as! [[String: Any]])[0]["id"] is String)
    let (linkedSnapshot, _) = try service.workSnapshot(root)
    let linkedConsumer = linkedSnapshot.document.references.first { $0.title == "Check the release" }!
    precondition(TaskCoordination.state(linkedConsumer, in: linkedSnapshot.document) == "blocked")
    let reopenedLegacyEdits = try linkedSnapshot.edits(linkedSnapshot.document)
    precondition(reopenedLegacyEdits.isEmpty)
    print("PASS: inline checklist work metadata preserves prose/tables; cross-page dependencies and loops remain consistent in folder views")

    let git = root.appendingPathComponent(".git"); try FileManager.default.createDirectory(at: git, withIntermediateDirectories: true)
    let next = queue[0]
    _ = call("claim_task", ["path": path, "expected_revision": next["revision"]!, "reference": next["reference"]!, "owner": "Codex / release"], fails: true)
    try AgentSetup.designate(root)
    page = call("claim_task", ["path": path, "expected_revision": next["revision"]!, "reference": next["reference"]!, "owner": "Codex / release"])
    let secondReceipt = page["claim_token"] as! String
    let configuration = root.appendingPathComponent(".omega/coordination.json"), original = try Data(contentsOf: configuration)
    try AssistantWire.json(["authority": "a-different-Mac"]).write(to: configuration)
    _ = call("release_task", ["path": path, "expected_revision": page["revision"]!, "reference": next["reference"]!, "claim_token": secondReceipt], fails: true)
    try original.write(to: configuration)
    page = call("release_task", ["path": path, "expected_revision": page["revision"]!, "reference": next["reference"]!, "claim_token": secondReceipt])
    print("PASS: shared Git replicas cannot claim work without the designated coordinator; another Mac cannot release its claims")

    let project = base.appendingPathComponent("Code"); try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
    try "# Existing rules\nDo not deploy.\n".write(to: project.appendingPathComponent("AGENTS.md"), atomically: true, encoding: .utf8)
    try AgentSetup.install(project: project, notebook: root)
    let setup = try String(contentsOf: project.appendingPathComponent("AGENTS.md"), encoding: .utf8)
    precondition(setup.hasPrefix("# Existing rules\nDo not deploy.\n") && setup.contains("claim_task"))
    try AgentSetup.install(project: project, notebook: root)
    let setupAgain = try String(contentsOf: project.appendingPathComponent("AGENTS.md"), encoding: .utf8)
    let backups = try FileManager.default.contentsOfDirectory(atPath: project.path).filter { $0.hasPrefix("AGENTS.md.omega-backup") }
    precondition(setupAgain == setup && backups.count == 1)
    let symlinkProject = base.appendingPathComponent("Linked"); try FileManager.default.createDirectory(at: symlinkProject, withIntermediateDirectories: true)
    try FileManager.default.createSymbolicLink(at: symlinkProject.appendingPathComponent("CLAUDE.md"), withDestinationURL: project.appendingPathComponent("AGENTS.md"))
    do { try AgentSetup.install(project: symlinkProject, notebook: root); preconditionFailure("Symlink setup accepted") } catch {}
    precondition(!FileManager.default.fileExists(atPath: symlinkProject.appendingPathComponent("AGENTS.md").path))
    // Generated by Beads 1.0.3: bd export --no-memories, in an isolated test project.
    let exported = """
    {"_type":"issue","id":"otest-launch.1","title":"Ship","description":"Ship after Build","notes":"Tests passed; review before release","status":"open","priority":2,"issue_type":"task","assignee":"Claude","owner":"omega@example.invalid","created_at":"2026-10-18T08:25:16Z","created_by":"Omega test","updated_at":"2026-10-18T08:25:16Z","labels":["launch"],"dependencies":[{"issue_id":"otest-launch.1","depends_on_id":"otest-build","type":"blocks","created_at":"2026-10-18T13:55:16Z","created_by":"Omega test","metadata":"{}"},{"issue_id":"otest-launch.1","depends_on_id":"otest-launch","type":"parent-child","created_at":"2026-10-18T13:55:15Z","created_by":"Omega test","metadata":"{}"}],"comments":[{"id":"01a14e1d-7957-7b17-84b0-6c4914ccaab3","issue_id":"otest-launch.1","author":"Omega Test","text":"Keep this review context","created_at":"2026-10-18T08:25:17Z"}],"dependency_count":1,"dependent_count":0,"comment_count":1}
    {"_type":"issue","id":"otest-build","title":"Build","description":"Build the fixture","status":"closed","priority":2,"issue_type":"task","owner":"omega@example.invalid","created_at":"2026-10-18T08:25:15Z","created_by":"Omega test","updated_at":"2026-10-18T08:25:17Z","closed_at":"2026-10-18T08:25:17Z","close_reason":"Closed","dependency_count":0,"dependent_count":1,"comment_count":0}
    {"_type":"issue","id":"otest-launch","title":"Launch","description":"Launch acceptance criteria","status":"open","priority":2,"issue_type":"epic","owner":"omega@example.invalid","created_at":"2026-10-18T08:25:13Z","created_by":"Omega test","updated_at":"2026-10-18T08:25:13Z","labels":["launch"],"dependency_count":0,"dependent_count":0,"comment_count":0}
    """
    let preview = try BeadsImport.preview(exported), imported = try TaskDocument(markdown: preview.markdown)
    precondition(preview.count == 3 && imported.tasks.count == 2 && imported.tasks.first { $0.title == "Launch" }?.subtasks.first?.title == "Ship")
    precondition(imported.tasks.first { $0.title == "Launch" }?.details.extra["beads"] != nil)
    precondition(imported.tasks.allSatisfy { $0.details.extra["omegaPriority"] == .number(2) })
    precondition(imported.references.first { $0.title == "Ship" }.map { TaskCoordination.state($0, in: imported) } == "assigned")
    do { _ = try BeadsImport.preview(exported + "\n" + exported); preconditionFailure("Duplicate Beads IDs accepted") } catch {}
    print("PASS: repeatable agent setup preserves existing rules, backups and symlink boundaries; Beads import retains hierarchy, dependencies, owners, notes and original records")
}
