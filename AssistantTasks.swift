import Foundation
import CoreFoundation

extension FolioMCP {
    static let priority: [String: Any] = ["type": "integer", "minimum": -1, "maximum": 4, "description": "P0 (urgent) through P4 (backlog). -1 clears the priority."]
    static let taskTargetFields: [String: Any] = [
        "task_id": property("Durable task ID from read_task or read_work_queue. Use together with expected_task_revision, without positional references."),
        "expected_task_revision": property("Task revision from read_task/queue. Changes to other tasks do not invalidate it; changes to this task, its parent or page statuses do. Read again on conflict."),
        "response_format": ["type": "string", "enum": ["compact", "page"], "description": "compact returns a small receipt; page retains the legacy full-page response. Task-ID requests default to compact."]
    ]
    static func enrichTaskTool(_ definition: [String: Any]) -> [String: Any] {
        var tool = definition, schema = tool["inputSchema"] as! [String: Any], fields = schema["properties"] as! [String: Any], required = schema["required"] as! [String]
        let name = tool["name"] as! String
        if taskMutationNames.contains(name) || workMutationNames.contains(name) {
            fields["response_format"] = taskTargetFields["response_format"]
            // Structural edits and positional goal links still require a whole-page revision.
            if name == "update_task" || workMutationNames.contains(name) {
                fields.merge(taskTargetFields) { _, new in new }
                required.removeAll { $0 == "expected_revision" || $0 == "reference" }
                tool["description"] = (tool["description"] as! String) + " Prefer task_id + expected_task_revision for independent task edits and compact receipts; legacy expected_revision + reference is supported."
            }
        }
        if name == "configure_task_statuses" { fields["claim_token"] = workFields["claim_token"] }
        if name == "read_work_queue" {
            fields.merge([
                "label": property("Only tasks with this label (case insensitive)."), "status": property("Exact task status."),
                "assignee": property("Exact owner/assignee (case insensitive)."), "query": property("Text contained in task title or description."),
                "priority": ["type": "integer", "minimum": 0, "maximum": 4, "description": "Filter explicit P0–P4 priority."],
                "limit": ["type": "integer", "minimum": 1, "maximum": 200, "description": "Page size, default 50."],
                "offset": ["type": "integer", "minimum": 0, "description": "Result offset, default 0."],
                "expected_queue_revision": property("Optional queue revision from the previous page; rejects paging across a changed queue."),
                "include_details": property("Include full descriptions and metadata; default false for compact results.", type: "boolean")
            ]) { _, new in new }
        }
        schema["properties"] = fields; schema["required"] = required; tool["inputSchema"] = schema; return tool
    }
    static var taskAPITools: [[String: Any]] {
        let fields: [String: Any] = ["op": ["type": "string", "enum": ["add", "update"]], "task_id": taskTargetFields["task_id"]!, "expected_task_revision": taskTargetFields["expected_task_revision"]!,
            "title": property("Task title; required for add."), "status": property("Existing page status."), "completed": property("Completion state; do not combine with status.", type: "boolean"),
            "client_id": property("Optional unique name for this added task inside this batch."), "parent_id": property("For add: existing parent ID, or $client_id of an earlier add in this batch.")].merging(taskFields) { _, new in new }
        return [
            tool("read_task", "Read one task or subtask, its durable ID, task revision, details, and direct child IDs. Use ensure_task_identity for legacy tasks before task-level updates. Does not return the whole page.", ["path": path, "task_id": taskTargetFields["task_id"]!, "reference": reference], required: ["path"]),
            tool("edit_tasks", "Atomically add/update up to 100 tasks on ONE page. Updates require task_id + expected_task_revision from a fresh read. Adds append without replacing existing tasks; parent_id may use $client_id from an earlier add. All operations validate before one save; any conflict leaves the page unchanged. Returns compact receipts. Never blindly retry timed-out additions: read the page to check whether they succeeded.", ["path": path, "expected_revision": property("Optional page-wide guard; omit to allow changes to unrelated tasks."), "operations": ["type": "array", "minItems": 1, "maxItems": 100, "items": ["type": "object", "properties": fields, "required": ["op"], "additionalProperties": false]]], required: ["path", "operations"], readOnly: false)
        ]
    }
}

@MainActor extension AssistantService {
    // The same recursive schema validation covers public tools and batch operations.
    func validateArguments(_ args: [String: Any], schema: [String: Any]) throws {
        for key in schema["required"] as? [String] ?? [] where args[key] == nil { throw AssistantError("Missing argument: " + key) }
        let fields = schema["properties"] as? [String: Any] ?? [:]
        for (key, value) in args {
            guard let field = fields[key] as? [String: Any] else { throw AssistantError("Unexpected argument: " + key) }
            try validateValue(value, schema: field, key: key)
        }
    }
    func validateValue(_ value: Any, schema: [String: Any], key: String) throws {
        let bool = (value as? NSNumber).map { CFGetTypeID($0) == CFBooleanGetTypeID() } ?? false
        switch schema["type"] as? String {
        case "string":
            guard let text = value as? String else { throw AssistantError("Invalid string: " + key) }
            if let values = schema["enum"] as? [String], !values.contains(text) { throw AssistantError("Invalid value: " + key) }
        case "boolean": guard bool else { throw AssistantError("Invalid boolean: " + key) }
        case "integer":
            guard let n = value as? NSNumber, !bool, n.doubleValue.isFinite, n.doubleValue.rounded() == n.doubleValue,
                  n.doubleValue >= ((schema["minimum"] as? NSNumber)?.doubleValue ?? Double(Int.min)), n.doubleValue <= ((schema["maximum"] as? NSNumber)?.doubleValue ?? Double(Int.max)) else { throw AssistantError("Invalid integer: " + key) }
        case "array":
            guard let values = value as? [Any], values.count >= (schema["minItems"] as? Int ?? 0), values.count <= (schema["maxItems"] as? Int ?? 12), let item = schema["items"] as? [String: Any] else { throw AssistantError("Invalid array: " + key) }
            for v in values { try validateValue(v, schema: item, key: key + "[]") }
        case "object":
            guard let object = value as? [String: Any] else { throw AssistantError("Invalid object: " + key) }
            try validateArguments(object, schema: schema)
        default: throw AssistantError("Unsupported argument: " + key)
        }
    }
    static func applyPriority(_ args: [String: Any], to details: inout TaskDetails) throws {
        if let priority = args["priority"] as? Int {
            guard (-1...4).contains(priority) else { throw AssistantError("Choose priority P0–P4, or -1 to clear.") }
            details.extra["omegaPriority"] = priority < 0 ? nil : .number(Double(priority))
        }
    }
    static func priorityOf(_ details: TaskDetails) -> Int? {
        if case .number(let value) = details.extra["omegaPriority"], value.isFinite, (0...4).contains(value), value.rounded() == value { return Int(value) }; return nil
    }
    static func taskRevision(_ ref: TaskReference, in document: TaskDocument) throws -> String {
        // Only this item's fields and ancestry participate. Sibling/child edits and
        // status-group reordering must not invalidate an independent task update.
        let parts = ref.reference.split(separator: ".")
        let ancestors = (1..<parts.count).map { count -> String in
            let path = parts.prefix(count).joined(separator: ".")
            return document.references.first { $0.reference == path }?.details.id ?? path
        }
        let value: [String: Any] = ["title": ref.title, "status": ref.status ?? "", "kind": ref.kind, "details": try JSONSerialization.jsonObject(with: JSONEncoder().encode(ref.details)), "ancestors": ancestors, "statuses": document.statuses, "completed": document.completedStatus]
        return AssistantWire.hash(String(decoding: AssistantWire.json(value), as: UTF8.self))
    }
    static func changedTaskIDs(_ before: TaskDocument, _ after: TaskDocument) -> Set<String> {
        let old = Dictionary(grouping: before.references.filter { $0.details.id != nil }, by: { $0.details.id! })
        return Set(after.references.compactMap { ref in
            guard let id = ref.details.id else { return nil }
            guard let previous = old[id]?.first, old[id]?.count == 1 else { return id }
            return (try? taskRevision(previous, in: before)) == (try? taskRevision(ref, in: after)) ? nil : id
        })
    }
    func uniqueTask(_ id: String, in document: TaskDocument) throws -> TaskReference {
        let refs = document.references.filter { $0.kind != "goal" && $0.details.id == id }
        guard refs.count == 1 else { throw AssistantError("Task ID is missing or ambiguous. Read the page again.") }; return refs[0]
    }
    func taskTarget(_ input: [String: Any], source: FolderTaskSource) throws -> [String: Any] {
        var args = input
        if let id = args["task_id"] as? String {
            guard args["reference"] == nil, args["task"] == nil, args["parent_task"] == nil, args["parent_reference"] == nil,
                  let expected = args["expected_task_revision"] as? String, source.persistedIDs.contains(id) else { throw AssistantError("Use a durable task_id with expected_task_revision, without positional references. Ensure legacy identity first.") }
            let ref = try uniqueTask(id, in: source.document)
            guard try Self.taskRevision(ref, in: source.document) == expected else { throw AssistantError("Conflict: this task changed. Read it again and merge your edit.") }
            if let page = args["expected_revision"] as? String, page != AssistantWire.hash(source.text) { throw AssistantError("Conflict: this page changed.") }
            args["reference"] = ref.reference; args["expected_revision"] = AssistantWire.hash(source.text)
            if args["response_format"] == nil { args["response_format"] = "compact" }
        } else {
            guard args["expected_task_revision"] == nil, args["expected_revision"] is String else { throw AssistantError("Supply expected_revision, or task_id + expected_task_revision.") }
        }
        return args
    }
    func taskSummary(_ ref: TaskReference, source: FolderTaskSource, details: Bool = false) throws -> [String: Any] {
        let id = ref.details.id, durable = id.map { source.persistedIDs.contains($0) } ?? false
        var result: [String: Any] = ["reference": ref.reference, "id": id as Any? ?? NSNull(), "durable_id": durable, "title": ref.title, "status": ref.status ?? "", "labels": ref.details.labels ?? [], "priority": Self.priorityOf(ref.details) as Any? ?? NSNull()]
        result["task_revision"] = durable ? try Self.taskRevision(ref, in: source.document) : NSNull()
        if details {
            var value = ref.details; value.extra.removeValue(forKey: "omegaClaim")
            result["details"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(value))
        }
        if let claim = TaskCoordination.claim(ref.details) { result["claimed_by"] = TaskCoordination.string(claim["owner"]) ?? "" }
        return result
    }
    func readTask(_ args: [String: Any]) throws -> [String: Any] {
        let url = try resolve(string(args, "path"), folder: false)
        let source = try FolderTaskSource(url: url, text: String(contentsOf: url, encoding: .utf8), preferences: notebook.taskPreferences)
        let ref: TaskReference
        if let id = args["task_id"] as? String {
            guard args["reference"] == nil else { throw AssistantError("Choose task_id or reference, not both.") }
            ref = try uniqueTask(id, in: source.document)
        } else {
            guard let reference = args["reference"] as? String, let found = source.document.references.first(where: { $0.reference == reference && $0.kind != "goal" }) else { throw AssistantError("Supply task_id or a current reference.") }; ref = found
        }
        var result = try taskSummary(ref, source: source, details: true)
        result["path"] = url.path; result["revision"] = AssistantWire.hash(source.text); result["statuses"] = source.document.statuses; result["completed_status"] = source.document.completedStatus
        let depth = ref.reference.split(separator: ".").count + 1
        let children = source.document.references.filter { $0.reference.hasPrefix(ref.reference + ".") && $0.reference.split(separator: ".").count == depth }
        result["children"] = children.map { child -> [String: Any] in ["id": child.details.id as Any? ?? NSNull(), "reference": child.reference, "title": child.title] }
        return result
    }
    func taskReceipt(_ url: URL, ids: Set<String>) throws -> [String: Any] {
        let source = try FolderTaskSource(url: url, text: String(contentsOf: url, encoding: .utf8), preferences: notebook.taskPreferences)
        return ["path": url.path, "revision": AssistantWire.hash(source.text), "items": try source.document.references.filter { ids.contains($0.details.id ?? "") }.map { try taskSummary($0, source: source) }]
    }
    func saveTaskChanges(_ source: FolderTaskSource, document: TaskDocument, changed: Set<String>, compact: Bool, completion: @escaping ([String: Any]) -> Void) throws {
        let next = try source.inline.map { try $0.render(document, persisting: changed) } ?? document.markdown
        try update(["path": source.url.path, "expected_revision": AssistantWire.hash(source.text), "markdown": next]) { response in
            guard response["isError"] as? Bool != true else { completion(response); return }
            do {
                var result = compact ? try self.taskReceipt(source.url, ids: changed) : try self.taskPage(source.url)
                if let saved = (response["structuredContent"] as? [String: Any])?["history_copy"] { result["history_copy"] = saved }
                completion(FolioMCP.success(result))
            } catch { completion(FolioMCP.failure(error.localizedDescription)) }
        }
    }
    func editTasks(_ args: [String: Any], completion: @escaping ([String: Any]) -> Void) throws {
        let url = try resolve(string(args, "path"), folder: false)
        guard !notebook.isArchived(url) else { throw AssistantError("Restore this page before editing tasks.") }
        let source = try FolderTaskSource(url: url, text: String(contentsOf: url, encoding: .utf8), preferences: notebook.taskPreferences)
        if args["expected_revision"] != nil { try checkRevision(url, args) }
        let operations = args["operations"] as! [[String: Any]]
        var document = source.document, aliases: [String: String] = [:], touched = Set<String>(), added = Set<String>()
        // No saves occur until all operations and ownership checks succeed.
        for operation in operations {
            var edit = operation
            if operation["op"] as? String == "update" {
                guard operation["client_id"] == nil, operation["parent_id"] == nil, let id = operation["task_id"] as? String,
                      touched.insert(id).inserted else { throw AssistantError("Each update needs a distinct task_id; parent/client IDs are only for adds.") }
                _ = try taskTarget(operation, source: source)
                edit["reference"] = try uniqueTask(id, in: document).reference
                try applyTaskMutation("update_task", edit, document: &document, url: url)
            } else {
                guard operation["task_id"] == nil, operation["expected_task_revision"] == nil, operation["completed"] == nil, operation["title"] is String else { throw AssistantError("Adds require a title; use status instead of completed.") }
                if let parent = operation["parent_id"] as? String {
                    let id: String
                    if parent.hasPrefix("$") { guard let value = aliases[String(parent.dropFirst())] else { throw AssistantError("Unknown parent client_id. Add the parent first.") }; id = value }
                    else { id = parent; guard source.persistedIDs.contains(id) else { throw AssistantError("Ensure a durable parent ID first.") } }
                    edit["parent_reference"] = try uniqueTask(id, in: document).reference
                }
                let before = Set(document.references.compactMap { $0.details.id })
                try applyTaskMutation("add_task", edit, document: &document, url: url)
                let newIDs = Set(document.references.compactMap { $0.details.id }).subtracting(before)
                guard newIDs.count == 1, let id = newIDs.first else { throw AssistantError("Could not identify the added task.") }
                added.insert(id)
                if let name = operation["client_id"] as? String {
                    guard !name.isEmpty, name.count <= 80, aliases[name] == nil else { throw AssistantError("Use distinct client_id values, 1–80 characters.") }; aliases[name] = id
                }
            }
        }
        let changed = Self.changedTaskIDs(source.document, document).union(added)
        try saveTaskChanges(source, document: document, changed: changed, compact: true) { response in
            var response = response
            if var result = response["structuredContent"] as? [String: Any] { result["created"] = aliases; response = FolioMCP.success(result) }
            completion(response)
        }
    }
}
