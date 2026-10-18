import Foundation

extension FolioMCP {
    static let workMutationNames: Set<String> = ["set_task_dependencies", "configure_task_work", "claim_task", "release_task", "handoff_task", "ensure_task_identity", "renew_task_claim"]
    static let workFields: [String: Any] = [
        "priority": priority, "audience": audience,
        "assignee": property("Person or agent responsible. Empty clears. Up to 200 characters."),
        "blocker": property("What is preventing progress. Empty clears."),
        "handoff": property("Persistent summary: decisions, completed work, tests, and next steps. Up to 12,000 characters."),
        "repository": property("Repository reference; Omega never executes it."), "branch": property("Branch managed by the coding agent."),
        "session": property("Agent session reference."), "pull_request": property("PR link."),
        "needs_review": property("Work is ready for human review, not yet completed.", type: "boolean"),
        "claim_token": property("Receipt returned by claim_task. Required to change claimed coordination fields or release a claim.")
    ]
    static let lease: [String: Any] = ["type":"integer", "minimum":60, "maximum":86400, "description":"Claim lease in seconds (60–86400). Default 1800 (30 minutes). Renew before expiry."]
    static var workTools: [[String: Any]] {
        let target: [String: Any] = ["path": path, "expected_revision": version, "reference": reference]
        return [
            tool("read_work_queue", "Read tasks and inline checklists under a notebook/folder, with dependency state, handoffs and source revisions. ready excludes blocked, claimed, assigned, draft, review and already-started work. Unavailable dependencies stay blocked. Inspect warnings before taking work.", ["path": path, "state": property("Optional ready, blocked, claimed, recoverable, human, assigned, working, review, done or draft filter.")], required: ["path"]),
            tool("ensure_task_identity", "Give a task a durable ID before another page links it. Works on task pages and inline checklists. Re-read after a conflict.", target, required: ["path", "expected_revision", "reference"], readOnly: false),
            tool("set_task_dependencies", "Replace blocked-by dependencies; rejects cycles and unresolved targets. Each entry is a relative note path followed by # and a durable task ID, e.g. Plan.md#task-id. Use ensure_task_identity for legacy targets. Empty array clears.", target.merging(["dependencies": ["type": "array", "items": ["type": "string"], "maxItems": 32], "claim_token": workFields["claim_token"]!]) { _, n in n }, required: ["path", "expected_revision", "reference", "dependencies"], readOnly: false),
            tool("configure_task_work", "Set assignment, blocker, handoff and execution references. Omega never starts agents or changes worktrees. Existing claims require their receipt.", target.merging(workFields) { _, n in n }, required: ["path", "expected_revision", "reference"], readOnly: false),
            tool("renew_task_claim", "Extend an unexpired claim using its receipt and current task revision. Expired receipts cannot renew or edit; read the handoff and reclaim first.", target.merging(["claim_token":workFields["claim_token"]!,"lease_seconds":lease]) { _, n in n }, required:["path","expected_revision","reference","claim_token"], readOnly:false),
            tool("claim_task", "Exclusively claim a Ready task through this Mac's Omega service. Returns a claim receipt; keep it for handoff/release. New claims expire after 30 minutes unless lease_seconds is specified. Expired work is recoverable, never automatically completed. Renew with renew_task_claim. Legacy claims remain manual. Git/live notebooks require a single designated Mac; configure it in Omega's agent setup first. Never assume a timed-out claim failed: read the task before retrying.", target.merging(["lease_seconds":lease, "owner": property("Unique agent/session label, e.g. Claude / auth-fix. Up to 200 characters.")]) { _, n in n }, required: ["path", "expected_revision", "reference", "owner"], readOnly: false),
            tool("release_task", "Release a claim using its receipt. Clears assignment; does not change task completion or erase the handoff. Read again before starting another task.", target.merging(["claim_token": workFields["claim_token"]!]) { _, n in n }, required: ["path", "expected_revision", "reference", "claim_token"], readOnly: false),
            tool("handoff_task", "Save a persistent handoff and release the claim. Defaults to needs_review=true; it never marks work completed. Set needs_review=false for unfinished work being handed to another agent.", target.merging(workFields) { _, n in n }, required: ["path", "expected_revision", "reference", "claim_token", "handoff"], readOnly: false)
        ]
    }
    static func callFromCLI(_ name: String) -> Int32 {
        do {
            let input = FileHandle.standardInput.readDataToEndOfFile()
            guard input.count < AssistantWire.maximum, let args = try JSONSerialization.jsonObject(with: input) as? [String: Any] else { throw AssistantError("Pass a JSON object on stdin.") }
            let fd = try AssistantWire.connect(); defer { close(fd) }
            try AssistantWire.write(AssistantWire.json(["name": name, "arguments": args, "clientName": "Omega agent CLI", "deadline": Date().timeIntervalSince1970 + 20]), to: fd)
            let result = try AssistantWire.read(fd); FileHandle.standardOutput.write(result + Data([10]))
            return ((try JSONSerialization.jsonObject(with: result)) as? [String: Any])?["isError"] as? Bool == true ? 1 : 0
        } catch { FileHandle.standardOutput.write(AssistantWire.json(failure(error.localizedDescription)) + Data([10])); return 1 }
    }
}

@MainActor extension AssistantService {
    func workSnapshot(_ root: URL, replacing: (URL, String)? = nil) throws -> (FolderTaskSnapshot, [String]) {
        let all = NoteFiles.flatten(try NoteFiles.scan(root)).filter { !$0.isFolder && !notebook.isArchived($0.url) }
        guard all.count <= 1500 else { throw AssistantError("Choose a smaller folder: the work queue supports up to 1,500 source pages.") }
        var sources: [FolderTaskSource] = [], warnings: [String] = []
        for entry in all {
            do {
                let url = try resolve(entry.url.path, folder: false)
                let text = replacing?.0 == url ? replacing!.1 : try String(contentsOf: url, encoding: .utf8)
                guard text.utf8.count <= 8_000_000 else { throw AssistantError("File exceeds 8 MB") }
                let source = try FolderTaskSource(url: url, text: text, preferences: notebook.taskPreferences)
                if !source.document.references.isEmpty { sources.append(source) }
            } catch { warnings.append(entry.url.lastPathComponent + ": " + error.localizedDescription) }
        }
        return (try FolderTaskSnapshot(folder: root, sources: sources, preferences: notebook.taskPreferences), warnings)
    }
    func workQueue(_ args: [String: Any]) throws -> [String: Any] {
        let root = try resolve(args["path"] as! String, folder: true), (snapshot, warnings) = try workSnapshot(root)
        let allowed = ["ready", "blocked", "claimed", "assigned", "working", "review", "done", "draft", "human", "recoverable"]
        if let state = args["state"] as? String, !allowed.contains(state) { throw AssistantError("Unknown work state.") }
        let revisions = Dictionary(uniqueKeysWithValues: snapshot.sources.map { ($0.key, AssistantWire.hash($0.text)) })
        let expiryStates = snapshot.document.references.filter { TaskCoordination.expired($0.details) }.compactMap { $0.details.id }.sorted().joined(separator:",")
        let queueRevision = AssistantWire.hash(expiryStates + revisions.map { $0.key + ":" + $0.value }.sorted().joined(separator: "\n") + String(decoding: AssistantWire.json(["statuses": snapshot.document.statuses, "completed": snapshot.document.completedStatuses]), as: UTF8.self))
        if let expected = args["expected_queue_revision"] as? String, expected != queueRevision { throw AssistantError("The queue changed while paging. Start at offset 0 again.") }
        let graph = TaskCoordination.Graph(snapshot.document)
        var rows: [[String: Any]] = []
        let lookup = Dictionary(uniqueKeysWithValues: snapshot.sources.map { ($0.key, $0) })
        for ref in snapshot.document.references where ref.kind != "goal" {
            let state = graph.state(ref)
            if let filter = args["state"] as? String, state != filter { continue }
            guard let key = FolderTaskSnapshot.string(ref.details.extra["_folderSource"]), let source = lookup[key],
                  let id = FolderTaskSnapshot.string(ref.details.extra["_folderID"]),
                  let original = source.document.references.first(where: { ($0.details.id ?? FolderTaskSnapshot.legacyID(source.key, $0.reference)) == id }) else { continue }
            if let audience = args["audience"] as? String, TaskCoordination.audience(original.details) != audience { continue }
            if let label = args["label"] as? String, !(original.details.labels ?? []).contains(where: { $0.caseInsensitiveCompare(label) == .orderedSame }) { continue }
            if let status = args["status"] as? String, original.status != status { continue }
            if let priority = args["priority"] as? Int, Self.priorityOf(original.details) != priority { continue }
            let owner = TaskCoordination.claim(original.details).flatMap { TaskCoordination.string($0["owner"]) } ?? TaskCoordination.text(original.details, "omegaAssignee")
            if let assignee = args["assignee"] as? String, owner.caseInsensitiveCompare(assignee) != .orderedSame { continue }
            if let query = args["query"] as? String, !(original.title + " " + (original.details.description ?? "")).localizedCaseInsensitiveContains(query) { continue }
            var row = try taskSummary(original, source: source, details: args["include_details"] as? Bool == true)
            row["path"] = source.url.path; row["revision"] = revisions[source.key]!; row["state"] = state
            row["assignee"] = owner; row["blocker"] = TaskCoordination.text(original.details, "omegaBlocker")
            row["dependencies"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(TaskCoordination.dependencies(original.details)))
            rows.append(row)
        }
        rows.sort { a, b in
            let ap = a["priority"] as? Int ?? 2, bp = b["priority"] as? Int ?? 2
            if ap != bp { return ap < bp }
            return (a["path"] as! String, a["reference"] as! String) < (b["path"] as! String, b["reference"] as! String)
        }
        let offset = args["offset"] as? Int ?? 0, limit = args["limit"] as? Int ?? 50
        let page = Array(rows.dropFirst(min(offset, rows.count)).prefix(limit))
        return ["tasks": page, "total": rows.count, "next_offset": offset < rows.count && page.count < rows.count - offset ? offset + page.count : NSNull(), "queue_revision": queueRevision, "warnings": warnings, "folder": root.path, "claim_scope": "Single designated Omega Mac; all claiming agents must use this authority."]
    }
    func requireClaimAuthority(_ url: URL) throws {
        // A Git replica cannot issue independent offline claims. A deliberately
        // configured coordinator is the only Mac allowed to claim shared tasks.
        var parent = url.deletingLastPathComponent(), git = false
        while parent.path != "/" {
            if FileManager.default.fileExists(atPath: parent.appendingPathComponent(".git").path) { git = true; break }
            parent.deleteLastPathComponent()
        }
        let live = LiveCollaboration.shared.configurations.contains { $0.enabled && url.path.hasPrefix($0.folder + "/") }
        guard git || live else { return }
        guard let root = notebook.owner(of: url),
              let data = try? Data(contentsOf: root.appendingPathComponent(".omega/coordination.json")),
              let value = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              value["authority"] as? String == AgentSetup.authority else {
            throw AssistantError("This is a shared notebook. In Settings → Assistants, designate one Mac as its task coordinator. All claiming agents must connect to that Mac; offline replicas cannot issue exclusive claims.")
        }
    }
    func mutateWork(_ name: String, _ input: [String: Any], completion: @escaping ([String: Any]) -> Void) throws {
        let url = try resolve(input["path"] as! String, folder: false)
        guard !notebook.isArchived(url) else { throw AssistantError("Restore this page before assigning work.") }
        let text = try String(contentsOf: url, encoding: .utf8), source = try FolderTaskSource(url: url, text: text, preferences: notebook.taskPreferences)
        let args = try taskTarget(input, source: source)
        try checkRevision(url, args)
        var document = source.document
        guard let reference = args["reference"] as? String else { throw AssistantError("Supply a task reference with its page revision, or a durable task ID and task revision.") }
        guard let ref = document.references.first(where: { $0.reference == reference && $0.kind != "goal" }) else { throw AssistantError("Choose a task from a fresh work queue.") }
        if let claim = TaskCoordination.claim(ref.details), name != "claim_task", name != "ensure_task_identity" {
            if TaskCoordination.expired(ref.details) && name != "release_task" && name != "handoff_task" { throw AssistantError("This claim expired. Read the task and claim it again before editing or renewing.") }
            guard let token = args["claim_token"] as? String, token == FolderTaskSnapshot.string(claim["token"]) else { throw AssistantError("This task is claimed. Supply its claim receipt or ask the owner to hand it off.") }
            try requireClaimAuthority(url)
        }
        let id = try document.ensureLinkID(reference)
        var receipt: String?
        if name == "claim_task" {
            try requireClaimAuthority(url)
            let root = notebook.owner(of: url)!, (snapshot, warnings) = try workSnapshot(root)
            guard warnings.isEmpty else { throw AssistantError("Some source pages could not be read. Fix them before claiming work: " + warnings[0]) }
            let virtual = FolderTaskSnapshot.identity(source.key, ref.details.id ?? FolderTaskSnapshot.legacyID(source.key, reference))
            guard let aggregate = snapshot.document.references.first(where: { $0.details.id == virtual }), ["ready", "recoverable"].contains(TaskCoordination.state(aggregate, in: snapshot.document)), TaskCoordination.audience(ref.details) == "agent" else { throw AssistantError("This task is not Ready. It may be blocked, assigned, claimed, in review, or complete. Refresh the work queue.") }
            let owner = (args["owner"] as! String).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !owner.isEmpty && owner.utf16.count <= 200 else { throw AssistantError("Use a person or agent/session name of 1–200 characters.") }
            receipt = UUID().uuidString.lowercased()
            try document.updateDetails(reference) { d in
                d.extra["omegaAssignee"] = .string(owner)
                d.extra["omegaClaim"] = .object(["owner": .string(owner), "token": .string(receipt!), "at": .string(ISO8601DateFormatter().string(from: Date())), "expires": .number(Date().timeIntervalSince1970 + Double(args["lease_seconds"] as? Int ?? 1800))])
            }
        } else if name == "renew_task_claim" {
            guard var record = TaskCoordination.claim(ref.details), !TaskCoordination.expired(ref.details) else { throw AssistantError("There is no unexpired claim to renew.") }
            record["expires"] = .number(Date().timeIntervalSince1970 + Double(args["lease_seconds"] as? Int ?? 1800))
            try document.updateDetails(reference) { $0.extra["omegaClaim"] = .object(record) }
        } else if name == "set_task_dependencies" {
            var dependencies: [TaskJSON] = []
            for link in args["dependencies"] as! [String] {
                guard let hash = link.lastIndex(of: "#") else { throw AssistantError("Use relative-page.md#task-id for each dependency.") }
                let path = String(link[..<hash]), targetID = String(link[link.index(after: hash)...])
                guard !path.hasPrefix("/"), !path.contains("\\"), !path.isEmpty else { throw AssistantError("Use a relative page path.") }
                let targetURL = try resolve(url.deletingLastPathComponent().appendingPathComponent(path).standardizedFileURL.path, folder: false)
                guard notebook.owner(of: targetURL) == notebook.owner(of: url), !notebook.isArchived(targetURL) else { throw AssistantError("Dependencies must be in the same notebook and not archived.") }
                let target = try FolderTaskSource(url: targetURL, text: String(contentsOf: targetURL, encoding: .utf8), preferences: notebook.taskPreferences)
                guard target.persistedIDs.contains(targetID), target.document.references.contains(where: { $0.details.id == targetID && $0.kind != "goal" }) else { throw AssistantError("Dependency not found or missing a durable ID. Use ensure_task_identity first.") }
                var dep: [String: TaskJSON] = ["id": .string(targetID)]
                if targetURL != url { dep["path"] = .string(FolderTaskSnapshot.relative(targetURL, from: url.deletingLastPathComponent())) }
                dependencies.append(.object(dep))
            }
            try document.updateDetails(reference) { $0.extra["omegaDependencies"] = dependencies.isEmpty ? nil : .array(dependencies) }
        } else if name != "ensure_task_identity" {
            if name == "release_task" || name == "handoff_task" {
                guard TaskCoordination.claim(ref.details) != nil else { throw AssistantError("There is no active claim to release.") }
            }
            let fields = ["assignee": "omegaAssignee", "blocker": "omegaBlocker", "handoff": "omegaHandoff", "repository": "omegaRepository", "branch": "omegaBranch", "session": "omegaSession", "pull_request": "omegaPR"]
            try document.updateDetails(reference) { d in
                for (key, meta) in fields { if let value = args[key] as? String { d.extra[meta] = value.isEmpty ? nil : .string(value) } }
                try Self.applyPriority(args, to: &d)
                if let audience = args["audience"] as? String { d.extra["omegaAudience"] = audience == "auto" ? nil : .string(audience) }
                if let review = args["needs_review"] as? Bool { d.extra["omegaReview"] = review ? .bool(true) : nil }
                if name == "release_task" || name == "handoff_task" { d.extra.removeValue(forKey: "omegaClaim"); d.extra.removeValue(forKey: "omegaAssignee") }
                if name == "handoff_task" { d.extra["omegaReview"] = args["needs_review"] as? Bool == false ? nil : .bool(true) }
            }
        }
        for ref in document.references { try ref.details.validate(child: ref.kind != "task") }
        let next = try source.inline.map { try $0.render(document, persisting: [id]) } ?? document.markdown
        if name == "set_task_dependencies" {
            let (snapshot, warnings) = try workSnapshot(notebook.owner(of: url)!, replacing: (url, next))
            guard warnings.isEmpty else { throw AssistantError("Fix unreadable task pages before changing dependencies: " + warnings[0]) }
            try TaskCoordination.rejectCycles(snapshot.document)
        }
        try update(["path": url.path, "expected_revision": args["expected_revision"]!, "markdown": next]) { response in
            if response["isError"] as? Bool == true { completion(response); return }
            do {
                var result = args["response_format"] as? String == "compact" ? try self.taskReceipt(url, ids: [id]) : try self.taskPage(url); result["item_id"] = id
                if let receipt { result["claim_token"] = receipt }
                completion(FolioMCP.success(result))
            } catch { completion(FolioMCP.failure(error.localizedDescription)) }
        }
    }
}
