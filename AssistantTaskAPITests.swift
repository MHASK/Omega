import Foundation

@MainActor func runTaskAPITests() throws {
    let base = FileManager.default.temporaryDirectory.appendingPathComponent("Omega-task-api-" + UUID().uuidString), root = base.appendingPathComponent("Notes")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: base) }
    let store = Notebook(recovery: DraftRecovery(directory: base.appendingPathComponent("Recovery"))); store.root = root; store.notebooks = [root]
    let service = AssistantService(store, history: base.appendingPathComponent("History"))
    func call(_ name: String, _ args: [String: Any] = [:], fails: Bool = false) -> [String: Any] {
        var response: [String: Any]?
        service.handle(["name": name, "arguments": args]) { response = $0 }
        if response == nil || response!["isError"] as? Bool != fails { print("TASK API TEST FAILURE", name, response ?? [:]) }
        precondition(response != nil && response!["isError"] as? Bool == fails, "\(name): \(String(describing: response))")
        return response!["structuredContent"] as? [String: Any] ?? [:]
    }
    let page = call("create_task_page", ["folder": root.path, "name": "Build"]), path = page["path"] as! String
    let batch = call("edit_tasks", ["path": path, "operations": (0..<16).map { ["op": "add", "client_id": "item\($0)", "title": "Work \($0)", "description": String(repeating: "Long context. ", count: 800), "priority": $0 % 5, "labels": [$0 % 2 == 0 ? "PR" : "design"]] as [String: Any] }])
    let ids = batch["created"] as! [String: String]
    precondition((batch["items"] as! [[String: Any]]).count == 16 && AssistantWire.json(batch).count < 16000)
    precondition((try? String(contentsOfFile: path, encoding: .utf8).count) ?? 0 > 120000)
    // Eight clients observed the SAME page version, then edited independent tasks.
    let observed = (0..<8).map { call("read_task", ["path": path, "task_id": ids["item\($0)"]!]) }
    for i in 0..<8 {
        let task = observed[i]
        let receipt = call("update_task", ["path": path, "task_id": task["id"]!, "expected_task_revision": task["task_revision"]!, "title": "Edited by client \(i)", "status": "In progress"])
        precondition(receipt["tasks"] == nil && AssistantWire.json(receipt).count < 2000)
    }
    for i in 0..<8 {
        let current = call("read_task", ["path": path, "task_id": observed[i]["id"]!])
        precondition(current["title"] as? String == "Edited by client \(i)")
    }
    _ = call("update_task", ["path": path, "task_id": observed[0]["id"]!, "expected_task_revision": observed[0]["task_revision"]!, "title": "Stale same-task write"], fails: true)
    _ = call("update_task", ["path": path, "task_id": observed[1]["id"]!, "reference": "t:0", "expected_task_revision": observed[1]["task_revision"]!, "title": "Confused target"], fails: true)
    print("PASS: 16 adds in one atomic save; compact receipts for a 120 KB page; eight independent task revisions survive reordering; stale same-task edits rejected")

    var current = call("read_task", ["path": path, "task_id": ids["item8"]!])
    let before = try Data(contentsOf: URL(fileURLWithPath: path))
    _ = call("edit_tasks", ["path": path, "operations": [["op": "update", "task_id": current["id"]!, "expected_task_revision": current["task_revision"]!, "title": "Should roll back"], ["op": "add", "title": "Invalid", "status": "Imaginary"]]], fails: true)
    precondition((try? Data(contentsOf: URL(fileURLWithPath: path))) == before)
    _ = call("edit_tasks", ["path": path, "operations": [["op": "add", "title": "Should roll back"], ["op": "update", "task_id": current["id"]!, "expected_task_revision": "stale", "title": "Fail"]]], fails: true)
    precondition((try? Data(contentsOf: URL(fileURLWithPath: path))) == before)
    _ = call("edit_tasks", ["path": path, "operations": [["op": "add", "title": "Bad", "priority": true]]], fails: true)
    _ = call("edit_tasks", ["path": path, "operations": [["op": "add", "title": "Bad", "priority": 5]]], fails: true)
    _ = call("edit_tasks", ["path": path, "operations": [["op": "add", "title": "Bad", "typo": "hidden"]]], fails: true)
    _ = call("edit_tasks", ["path": path, "operations": []], fails: true)
    _ = call("edit_tasks", ["path": path, "operations": Array(repeating: ["op": "add", "title": "Overflow"], count: 101)], fails: true)
    _ = call("claim_task", ["path": path, "expected_revision": current["revision"]!, "owner": "Missing reference"], fails: true)
    let claim = call("claim_task", ["path": path, "task_id": current["id"]!, "expected_task_revision": current["task_revision"]!, "owner": "Agent A"]), token = claim["claim_token"]!
    current = call("read_task", ["path": path, "task_id": current["id"]!])
    _ = call("edit_tasks", ["path": path, "operations": [["op": "add", "title": "Should roll back"], ["op": "update", "task_id": current["id"]!, "expected_task_revision": current["task_revision"]!, "title": "Wrong owner"]]], fails: true)
    _ = call("edit_tasks", ["path": path, "operations": [["op": "update", "task_id": current["id"]!, "expected_task_revision": current["task_revision"]!, "claim_token": token, "priority": 0, "title": "Owner edit"]]])
    current = call("read_task", ["path": path, "task_id": current["id"]!])
    _ = call("handoff_task", ["path": path, "task_id": current["id"]!, "expected_task_revision": current["task_revision"]!, "claim_token": token, "handoff": "Verified owner edit."])
    print("PASS: atomic rollback, strict nested schema/bounds, task-scoped claims and handoffs, same-page ownership enforced")

    let family = call("edit_tasks", ["path": path, "operations": [["op": "add", "client_id": "parent", "title": "Parent"], ["op": "add", "client_id": "child", "parent_id": "$parent", "title": "Child"], ["op": "add", "client_id": "grandchild", "parent_id": "$child", "title": "Grandchild"]]])
    let familyIDs = family["created"] as! [String: String]
    let child = call("read_task", ["path": path, "task_id": familyIDs["child"]!]), grandchild = call("read_task", ["path": path, "task_id": familyIDs["grandchild"]!])
    _ = call("edit_tasks", ["path": path, "operations": [["op": "update", "task_id": child["id"]!, "expected_task_revision": child["task_revision"]!, "title": "Updated child"], ["op": "update", "task_id": grandchild["id"]!, "expected_task_revision": grandchild["task_revision"]!, "title": "Updated grandchild"]]])
    let owner = call("read_task", ["path": path, "task_id": familyIDs["parent"]!])
    let owned = call("claim_task", ["path": path, "task_id": owner["id"]!, "expected_task_revision": owner["task_revision"]!, "owner": "Parent agent"])
    _ = call("edit_tasks", ["path": path, "operations": [["op": "add", "parent_id": familyIDs["parent"]!, "title": "Unauthorized child"]]], fails: true)
    _ = call("edit_tasks", ["path": path, "operations": [["op": "add", "parent_id": familyIDs["parent"]!, "claim_token": owned["claim_token"]!, "title": "Authorized child"]]])
    let ready = call("read_work_queue", ["path": root.path, "state": "ready", "label": "pr", "priority": 0, "limit": 1])
    precondition((ready["tasks"] as! [[String: Any]]).count == 1 && (ready["tasks"] as! [[String: Any]])[0]["details"] == nil)
    let all = call("read_work_queue", ["path": root.path, "limit": 2]);precondition(all["next_offset"] as? Int == 2)
    let second = call("read_work_queue", ["path": root.path, "limit": 2, "offset": 2, "expected_queue_revision": all["queue_revision"]!]);precondition((second["tasks"] as! [[String: Any]]).count == 2)
    _ = call("read_work_queue", ["path": root.path, "expected_queue_revision": "stale", "offset": 2], fails: true)
    _ = call("read_work_queue", ["path": root.path, "limit": -1], fails: true)
    _ = call("read_work_queue", ["path": root.path, "priority": 7], fails: true)
    print("PASS: nested batch creation, parent claims, priority/label/ready filters, compact paginated queries and stale-page detection")

    let note = call("create_note", ["folder": root.path, "name": "Inline", "markdown": "# Plan\n\nKeep this prose.\n\n- [ ] Check it\n\n| Key | Value |\n| --- | --- |\n| A | B |\n"])
    let identity = call("ensure_task_identity", ["path": note["path"]!, "expected_revision": note["revision"]!, "reference": "t:0", "response_format": "compact"])
    var task = call("read_task", ["path": note["path"]!, "task_id": identity["item_id"]!])
    _ = call("edit_tasks", ["path": note["path"]!, "operations": [["op": "update", "task_id": task["id"]!, "expected_task_revision": task["task_revision"]!, "priority": 1, "completed": true]]])
    let text = try String(contentsOfFile: note["path"] as! String, encoding: .utf8)
    precondition(text.contains("Keep this prose.") && text.contains("| A | B |") && text.contains("[x] Check it"))
    task = call("read_task", ["path": note["path"]!, "task_id": identity["item_id"]!]);precondition(task["priority"] as? Int == 1)
    _ = call("configure_task_work", ["path": note["path"]!, "task_id": task["id"]!, "expected_task_revision": task["task_revision"]!, "priority": -1])
    task = call("read_task", ["path": note["path"]!, "task_id": identity["item_id"]!]);precondition(task["priority"] is NSNull)
    let settingsSnapshot = call("read_task", ["path": path, "task_id": ids["item9"]!])
    _ = call("configure_task_statuses", ["path": path, "expected_revision": settingsSnapshot["revision"]!, "statuses": ["To do", "In progress", "Review", "Done"], "completed_status": "Done", "claim_token": owned["claim_token"]!])
    _ = call("update_task", ["path": path, "task_id": settingsSnapshot["id"]!, "expected_task_revision": settingsSnapshot["task_revision"]!, "title": "Stale status assumptions"], fails: true)
    print("PASS: inline task revisions and priority round-trip preserve prose and tables; status configuration invalidates stale task assumptions")
}
