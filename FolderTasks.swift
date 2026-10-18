import Foundation
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif

/// A folder is a projection over its pages, never a second task database.
struct FolderTaskSource {
    let url: URL
    let text: String
    let key: String
    var document: TaskDocument
    let inline: InlineTaskDocument?
    let persistedIDs: Set<String>
    init(url: URL, text: String, preferences: TaskPreferences) throws {
        self.url = url; self.text = text; key = "s" + FolderTaskSnapshot.hash(url.standardizedFileURL.path).prefix(12)
        if TaskDocument.isTaskPage(text) { document = try TaskDocument(markdown: text); inline = nil; persistedIDs = Set(document.references.compactMap { $0.details.id }) }
        else {
            let sourceKey = key
            var note = try InlineTaskDocument(text, preferences: preferences)
            persistedIDs = Set(note.document.references.compactMap { $0.details.id })
            func install(_ d: inout TaskDetails, _ ref: String) { if d.id == nil { d.id = FolderTaskSnapshot.legacyID(sourceKey, ref) } }
            func children(_ items: inout [TaskCheckItem], _ prefix: String) {
                for i in items.indices { let ref = prefix + ".\(i)"; install(&items[i].details, ref); children(&items[i].subtasks, ref) }
            }
            for i in note.document.goals.indices { install(&note.document.goals[i].details, "g:\(i)") }
            for i in note.document.tasks.indices { install(&note.document.tasks[i].details, "t:\(i)"); children(&note.document.tasks[i].subtasks, "t:\(i)") }
            for i in note.rows.indices { note.rows[i].details.id = note.document.references.first { $0.reference == note.rows[i].ref }?.details.id }
            inline = note; document = note.document
        }
    }
}

struct FolderTaskSnapshot {
    let folder: URL
    let sources: [FolderTaskSource]
    var document: TaskDocument
    // Virtual identities are qualified by source; copied IDs in different files cannot collide.
    static func hash(_ value: String) -> String { SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined() }
    static func identity(_ source: String, _ original: String) -> String { source + "_" + (original.count <= 64 ? original : String(hash(original).prefix(40))) }
    static func string(_ value: TaskJSON?) -> String? { if case .string(let s) = value { return s }; return nil }
    static func equal<T: Encodable>(_ lhs: T, _ rhs: T) -> Bool {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return (try? encoder.encode(lhs)) == (try? encoder.encode(rhs))
    }
    init(folder: URL, sources: [FolderTaskSource], preferences: TaskPreferences) throws {
        self.folder = folder; self.sources = sources
        var aggregate = TaskDocument(title: folder.lastPathComponent + " tasks", preferences: preferences)
        var goalIDs: [String: Set<String>] = [:]
        for source in sources {
            goalIDs[source.key] = Set(source.document.goals.enumerated().map { $0.element.details.id ?? Self.legacyID(source.key, "g:\($0.offset)") })
        }
        func status(_ name: String, in source: FolderTaskSource) -> String {
            if name == source.document.completedStatus { return aggregate.completedStatus }
            let name = name.caseInsensitiveCompare(aggregate.completedStatus) == .orderedSame ? String(name.prefix(32)) + " (open)" : name
            if let existing = aggregate.statuses.first(where: { $0.caseInsensitiveCompare(name) == .orderedSame }) { return existing }
            aggregate.statuses.insert(name, at: max(0, aggregate.statuses.count - 1)); return name
        }
        func details(_ original: TaskDetails, ref: String, source: FolderTaskSource) -> TaskDetails {
            var d = original
            let id = d.id ?? Self.legacyID(source.key, ref)
            d.id = Self.identity(source.key, id); d.extra["_folderSource"] = .string(source.key); d.extra["_folderID"] = .string(id)
            let links: [String: TaskJSON]
            if case .object(let value) = d.extra["omegaGoalSources"] { links = value } else { links = [:] }
            d.goals = d.goals?.map { goal in
                let path: String?, targetID: String
                if case .object(let record) = links[goal] { path = Self.string(record["path"]); targetID = Self.string(record["id"]) ?? goal }
                else { path = Self.string(links[goal]); targetID = goal }
                if let path {
                    let url = source.url.deletingLastPathComponent().appendingPathComponent(path).standardizedFileURL
                    if let other = sources.first(where: { $0.url.standardizedFileURL == url }), goalIDs[other.key]?.contains(targetID) == true { return Self.identity(other.key, targetID) }
                    let matches = sources.filter { goalIDs[$0.key]?.contains(targetID) == true }
                    if matches.count == 1 { return Self.identity(matches[0].key, targetID) }
                }
                return goalIDs[source.key]?.contains(goal) == true ? Self.identity(source.key, goal) : goal
            }
            if d.extra["omegaDependencies"] != nil {
                d.extra["omegaDependencies"] = .array(TaskCoordination.dependencies(original).map { dep in
                    guard let targetID = Self.string(dep["id"]) else { return .object(dep) }
                    let targetURL = Self.string(dep["path"]).map { source.url.deletingLastPathComponent().appendingPathComponent($0).standardizedFileURL } ?? source.url
                    guard let target = sources.first(where: { $0.url.standardizedFileURL == targetURL }),
                          target.document.references.contains(where: { $0.kind != "goal" && ($0.details.id ?? Self.legacyID(target.key, $0.reference)) == targetID }) else { return .object(dep) }
                    return .object(["id": .string(Self.identity(target.key, targetID))])
                })
            }
            return d
        }
        for source in sources {
            for name in source.document.statuses { _ = status(name, in: source) }
            func child(_ item: TaskCheckItem, ref: String) -> TaskCheckItem {
                var result = item; result.details = details(item.details, ref: ref, source: source)
                result.details.status = status(source.document.status(of: item), in: source)
                result.completed = result.details.status == aggregate.completedStatus
                result.subtasks = item.subtasks.enumerated().map { child($0.element, ref: ref + ".\($0.offset)") }; return result
            }
            aggregate.goals += source.document.goals.enumerated().map { index, g in
                var g = g; g.details = details(g.details, ref: "g:\(index)", source: source); return g
            }
            aggregate.tasks += source.document.tasks.enumerated().map { index, task in
                var task = task; task.status = status(task.status, in: source)
                task.details = details(task.details, ref: "t:\(index)", source: source)
                task.subtasks = task.subtasks.enumerated().map { child($0.element, ref: "t:\(index).\($0.offset)") }; return task
            }
        }
        try TaskPreferences(statuses: aggregate.statuses, completed: aggregate.completedStatus).validate()
        document = aggregate
    }
    static func legacyID(_ source: String, _ ref: String) -> String { "omega-" + hash(source + ":" + ref).prefix(32) }

    struct Edit { let url: URL; let before: String; let after: String }
    /// Validate the complete proposal before any file is written. Callers also
    /// compare every changed file's exact revision immediately before saving.
    func edits(_ proposal: TaskDocument) throws -> [Edit] {
        guard proposal.title == document.title, proposal.statuses == document.statuses, proposal.completedStatus == document.completedStatus else { throw TaskPageError("Folder settings changed. Refresh the task view before editing.") }
        let sourceKeys = Set(sources.map(\.key))
        let all = proposal.references
        for ref in all {
            guard let key = Self.string(ref.details.extra["_folderSource"]), sourceKeys.contains(key),
                  let original = Self.string(ref.details.extra["_folderID"]), ref.details.id == Self.identity(key, original) else { throw TaskPageError("Choose a source page for this item.") }
        }
        var goals: [String: (source: FolderTaskSource, id: String)] = [:]
        for g in proposal.goals {
            let key = Self.string(g.details.extra["_folderSource"])!
            goals[g.details.id!] = (sources.first { $0.key == key }!, Self.string(g.details.extra["_folderID"])!)
        }
        var taskTargets: [String: (source: FolderTaskSource, id: String)] = [:]
        for ref in all where ref.kind != "goal" {
            let key = Self.string(ref.details.extra["_folderSource"])!
            taskTargets[ref.details.id!] = (sources.first { $0.key == key }!, Self.string(ref.details.extra["_folderID"])!)
        }
        // Recovered external cycles stay readable; new dependency edits cannot introduce one.
        let dependenciesChanged = proposal.references.contains { ref in
            let old = document.references.first { $0.details.id == ref.details.id }
            return ref.details.extra["omegaDependencies"] != old?.details.extra["omegaDependencies"]
        }
        if dependenciesChanged { try TaskCoordination.rejectCycles(proposal) }
        let referencedTasks = Set(all.flatMap { TaskCoordination.dependencies($0.details).compactMap { $0["path"] == nil ? Self.string($0["id"]) : nil } })
        func subset(_ doc: TaskDocument, _ key: String) -> TaskDocument {
            var d = doc; d.goals = d.goals.filter { Self.string($0.details.extra["_folderSource"]) == key }
            d.tasks = d.tasks.filter { Self.string($0.details.extra["_folderSource"]) == key }; return d
        }
        var result: [Edit] = []
        for source in sources {
            let desired = subset(proposal, source.key), previous = subset(document, source.key)
            let referencedGoals = Set(proposal.references.filter { $0.kind != "goal" }.flatMap { $0.details.goals ?? [] })
            let needsGoalIdentity = desired.goals.contains { goal in
                referencedGoals.contains(goal.details.id ?? "") && !source.persistedIDs.contains(Self.string(goal.details.extra["_folderID"]) ?? "")
            }
            let needsTaskIdentity = desired.references.contains { ref in
                referencedTasks.contains(ref.details.id ?? "") && !source.persistedIDs.contains(Self.string(ref.details.extra["_folderID"]) ?? "")
            }
            guard needsGoalIdentity || needsTaskIdentity || !Self.equal(desired, previous) else { continue }
            var output = source.document
            func localStatus(_ name: String) -> String {
                if name == proposal.completedStatus { return output.completedStatus }
                if name == String(proposal.completedStatus.prefix(32)) + " (open)", output.statuses.contains(proposal.completedStatus), output.completedStatus != proposal.completedStatus { return proposal.completedStatus }
                if let match = output.statuses.first(where: { $0.caseInsensitiveCompare(name) == .orderedSame }) { return match }
                if !output.statuses.contains(name) { output.statuses.insert(name, at: max(0, output.statuses.count - 1)) }
                return name
            }
            func localDetails(_ input: TaskDetails) throws -> TaskDetails {
                guard Self.string(input.extra["_folderSource"]) == source.key else { throw TaskPageError("Move a task within its source page. Tasks from different pages can share goals.") }
                var d = input; d.id = Self.string(d.extra.removeValue(forKey: "_folderID")); d.extra.removeValue(forKey: "_folderSource")
                var links: [String: TaskJSON] = [:]
                if case .object(let old) = d.extra["omegaGoalSources"] { links = old }
                d.goals = d.goals?.map { virtual in
                    guard let goal = goals[virtual] else { return virtual }
                    if goal.source.key != source.key {
                        let path = Self.relative(goal.source.url, from: source.url.deletingLastPathComponent())
                        let alias = "goal-" + Self.hash(path + "#" + goal.id).prefix(40)
                        links[alias] = .object(["path": .string(path), "id": .string(goal.id)])
                        return alias
                    }
                    links.removeValue(forKey: goal.id); return goal.id
                }
                links = links.filter { (d.goals ?? []).contains($0.key) }
                if links.isEmpty { d.extra.removeValue(forKey: "omegaGoalSources") } else { d.extra["omegaGoalSources"] = .object(links) }
                if d.extra["omegaDependencies"] != nil {
                    d.extra["omegaDependencies"] = .array(TaskCoordination.dependencies(d).map { dep in
                        guard dep["path"] == nil, let virtual = Self.string(dep["id"]), let target = taskTargets[virtual] else { return .object(dep) }
                        var record: [String: TaskJSON] = ["id": .string(target.id)]
                        if target.source.key != source.key { record["path"] = .string(Self.relative(target.source.url, from: source.url.deletingLastPathComponent())) }
                        return .object(record)
                    })
                }
                return d
            }
            func child(_ input: TaskCheckItem) throws -> TaskCheckItem {
                var c = input; c.details = try localDetails(c.details)
                c.details.status = localStatus(proposal.status(of: input)); c.completed = c.details.status == output.completedStatus
                c.subtasks = try c.subtasks.map(child); return c
            }
            output.goals = try desired.goals.map { g in var g = g; g.details = try localDetails(g.details); return g }
            output.tasks = try desired.tasks.map { task in
                var task = task; task.status = localStatus(task.status); task.details = try localDetails(task.details)
                task.subtasks = try task.subtasks.map(child); return task
            }
            // Legacy IDs are only persisted when a page actually changes.
            try TaskPreferences(statuses: output.statuses, completed: output.completedStatus).validate()
            let requiredIDs = Set(desired.references.filter { referencedTasks.contains($0.details.id ?? "") }.compactMap { Self.string($0.details.extra["_folderID"]) })
            let text = try source.inline.map { try $0.render(output, persisting: requiredIDs) } ?? output.markdown
            if text != source.text { result.append(Edit(url: source.url, before: source.text, after: text)) }
        }
        return result
    }
    static func relative(_ url: URL, from base: URL) -> String {
        let a = base.standardizedFileURL.pathComponents, b = url.standardizedFileURL.pathComponents
        var common = 0; while common < min(a.count, b.count), a[common] == b[common] { common += 1 }
        return (Array(repeating: "..", count: a.count - common) + b.dropFirst(common)).joined(separator: "/")
    }
}

/// Inline task details live in a hidden, losslessly preserved Markdown comment.
/// Prose, tables, code, and other checklists are never regenerated as a task page.
struct InlineTaskDocument {
    struct Row { var item: NoteChecklistItem; var range: NSRange; var details: TaskDetails; var title: String; var ref: String = ""; var persisted = false }
    let source: String
    var rows: [Row] = []
    var document: TaskDocument
    init(_ source: String, preferences: TaskPreferences) throws {
        self.source = source; document = TaskDocument(preferences: preferences)
        let ns = source as NSString
        for item in NoteChecklist.items(in: source) {
            let range = ns.lineRange(for: NSRange(location: item.offset, length: 0))
            let line = ns.substring(with: range).trimmingCharacters(in: .newlines)
            var title = item.title, details = TaskDetails()
            if let start = line.range(of: "<!-- omega-task:") {
                guard let end = line.range(of: "-->", range: start.upperBound..<line.endIndex), line[end.upperBound...].trimmingCharacters(in: .whitespaces).isEmpty else { throw TaskPageError("An inline task has unfinished details. Open its source page to repair it.") }
                details = try TaskDetails.decode(String(line[start.upperBound..<end.lowerBound]).trimmingCharacters(in: .whitespaces), child: true)
                title = String(item.title.components(separatedBy: "<!-- omega-task:")[0]).trimmingCharacters(in: .whitespaces)
            }
            rows.append(Row(item: item, range: range, details: details, title: title, persisted: details.id != nil))
        }
        var seen = Set<String>(), stack: [(depth: Int, path: [Int])] = []
        for index in rows.indices {
            var row = rows[index]
            if let id = row.details.id, !seen.insert(id).inserted { throw TaskPageError("Two inline tasks share an ID. Open their source page to repair it.") }
            let done = row.item.completed
            // Editing a checkbox in a note always wins over an old status field.
            let configured = row.details.status ?? (done ? document.completedStatus : document.statuses.first { $0 != document.completedStatus } ?? document.completedStatus)
            let status = done ? document.completedStatus : configured == document.completedStatus ? document.statuses.first { $0 != document.completedStatus } ?? configured : configured
            if !document.statuses.contains(status) { document.statuses.append(status) }
            var details = row.details; details.status = status
            let child = TaskCheckItem(title: row.title, completed: done, details: details)
            if FolderTaskSnapshot.string(details.extra["omegaKind"]) == "goal" {
                details.status = nil; document.goals.append(TaskCheckItem(title: row.title, completed: done, details: details)); row.ref = "g:\(document.goals.count - 1)"; stack = []
            } else {
                stack.removeAll { $0.depth >= row.item.depth }
                if let parent = stack.last {
                    var path = parent.path
                    if path.count == 1 {
                        let n = document.tasks[path[0]].subtasks.count; document.tasks[path[0]].subtasks.append(child); path.append(n)
                    } else {
                        document.tasks[path[0]].subtasks[path[1]].update(at: path.dropFirst(2)) { target in let n = target.subtasks.count; target.subtasks.append(child); path.append(n) }
                    }
                    stack.append((row.item.depth, path)); row.ref = "t:" + path.map(String.init).joined(separator: ".")
                } else {
                    details.status = nil; document.tasks.append(TaskPageItem(title: row.title, status: status, details: details))
                    let path = [document.tasks.count - 1]; stack.append((row.item.depth, path)); row.ref = "t:\(path[0])"
                }
            }
            rows[index] = row
        }
    }
    func render(_ proposed: TaskDocument, persisting requiredIDs: Set<String> = []) throws -> String {
        let old = document.references
        // Match rows by their old explicit ID; untouched legacy rows use the same
        // generated IDs assigned by the folder source adapter.
        var ordered: [(id: String, text: String, depth: Int)] = []
        let newline = source.contains("\r\n") ? "\r\n" : "\n"
        func line(_ title: String, _ done: Bool, _ details: TaskDetails, _ depth: Int, goal: Bool = false) throws {
            var details = details; if goal { details.extra["omegaKind"] = .string("goal") }
            guard let id = details.id else { throw TaskPageError("Missing inline task identity.") }
            try details.validate(child: true)
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            let json = String(decoding: try encoder.encode(details), as: UTF8.self).replacingOccurrences(of: "<", with: "\\u003c").replacingOccurrences(of: ">", with: "\\u003e")
            let text = String(repeating: "  ", count: depth) + "- [\(done ? "x" : " ")] " + title.replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "\r", with: " ") + " <!-- omega-task: " + json + " -->" + newline
            ordered.append((id, text, depth))
        }
        for goal in proposed.goals { try line(goal.title, proposed.goalProgress(goal).done, goal.details, 0, goal: true) }
        func child(_ c: TaskCheckItem, _ depth: Int) throws { try line(c.title, proposed.status(of: c) == proposed.completedStatus, c.details, depth); for next in c.subtasks { try child(next, depth + 1) } }
        for task in proposed.tasks { var d = task.details; d.status = task.status; try line(task.title, task.status == proposed.completedStatus, d, 0); for c in task.subtasks { try child(c, 1) } }
        // Row IDs are installed in a copy before rendering; text ranges stay exact.
        let keys = rows.map { $0.details.id ?? "" }
        guard !keys.contains("") else { throw TaskPageError("Inline task identities were not prepared.") }
        func parentMap(_ document: TaskDocument) -> [String: String] {
            Dictionary(uniqueKeysWithValues: document.references.map { ref in
                (ref.details.id!, ref.folderParentReference.flatMap { p in document.references.first { $0.reference == p }?.details.id } ?? "")
            })
        }
        let oldParents = parentMap(document), parents = parentMap(proposed)
        let byID = Dictionary(uniqueKeysWithValues: ordered.map { ($0.id, $0) })
        var incoming = Set(ordered.filter { oldParents[$0.id] == nil || oldParents[$0.id] != parents[$0.id] }.map(\.id))
        // Moving the same task carries its complete task subtree and metadata.
        var grew = true
        while grew { let previous = incoming.count; for (id, parent) in parents where incoming.contains(parent) { incoming.insert(id) }; grew = previous != incoming.count }
        var replacements: [(NSRange, String)] = [], newAt: [Int: String] = [:]
        for row in rows {
            guard let replacement = byID[row.details.id!], !incoming.contains(row.details.id!) else { replacements.append((row.range, "")); continue }
            let previous = old.first { $0.reference == row.ref }
            let next = proposed.references.first { $0.details.id == replacement.id }
            if let previous, let next, previous.title == next.title, previous.status == next.status,
               FolderTaskSnapshot.equal(previous.details, next.details), !(!row.persisted && (next.kind == "goal" || requiredIDs.contains(replacement.id))) { continue }
            // Keep the source note's existing indentation for an in-place edit.
            let prefix = (source as NSString).substring(with: row.range).prefix { $0 == " " || $0 == "\t" }
            replacements.append((row.range, String(prefix) + replacement.text.drop { $0 == " " }))
        }
        func descendant(_ id: String, of ancestor: String, in map: [String: String]) -> Bool {
            var p = map[id] ?? "", visited = Set<String>()
            while !p.isEmpty, visited.insert(p).inserted { if p == ancestor { return true }; p = map[p] ?? "" }; return false
        }
        for item in ordered where incoming.contains(item.id) && !incoming.contains(parents[item.id] ?? "") {
            let parent = parents[item.id] ?? "", parentRow = rows.first { $0.details.id == parent }
            let position: Int
            if let parentRow {
                let descendants = rows.filter { !incoming.contains($0.details.id!) && byID[$0.details.id!] != nil && descendant($0.details.id!, of: parent, in: oldParents) }
                position = NSMaxRange(descendants.last?.range ?? parentRow.range)
            } else { position = (source as NSString).length }
            let family = ordered.filter { $0.id == item.id || descendant($0.id, of: item.id, in: parents) }
            let baseDepth = parentRow.map { $0.item.depth + 1 } ?? 0
            let text = family.map { line in String(repeating: "  ", count: max(0, baseDepth + line.depth - item.depth)) + line.text.drop { $0 == " " } }.joined()
            newAt[position, default: ""] += text
        }
        for (position, text) in newAt { replacements.append((NSRange(location: position, length: 0), (position == (source as NSString).length && !source.isEmpty && !source.hasSuffix("\n") ? newline : "") + text)) }
        let result = NSMutableString(string: source)
        for (range, text) in replacements.sorted(by: { $0.0.location == $1.0.location ? $0.0.length > $1.0.length : $0.0.location > $1.0.location }) { result.replaceCharacters(in: range, with: text) }
        return result as String
    }
}

private extension TaskReference {
    var folderParentReference: String? {
        guard kind == "subtask", let dot = reference.lastIndex(of: ".") else { return nil }
        return String(reference[..<dot])
    }
}
