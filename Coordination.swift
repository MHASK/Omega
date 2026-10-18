import Foundation

// Stored as extension metadata so older readers preserve every coordination field.
enum TaskCoordination {
    static func string(_ value: TaskJSON?) -> String? { if case .string(let s) = value { return s }; return nil }
    static let textFields = ["omegaAssignee", "omegaBlocker", "omegaHandoff", "omegaRepository", "omegaBranch", "omegaSession", "omegaPR"]
    static func text(_ details: TaskDetails, _ key: String) -> String { string(details.extra[key]) ?? "" }
    static func dependencies(_ details: TaskDetails) -> [[String: TaskJSON]] {
        guard case .array(let values) = details.extra["omegaDependencies"] else { return [] }
        return values.compactMap { if case .object(let o) = $0 { return o }; return nil }
    }
    static func claim(_ details: TaskDetails) -> [String: TaskJSON]? {
        if case .object(let o) = details.extra["omegaClaim"] { return o }; return nil
    }
    static func validate(_ details: TaskDetails) throws {
        for key in textFields where details.extra[key] != nil {
            guard case .string(let value) = details.extra[key], value.utf16.count <= (key == "omegaHandoff" ? 12000 : 200), !value.contains("\0") else { throw TaskPageError("Invalid work field: " + key) }
        }
        if let priority = details.extra["omegaPriority"] {
            guard case .number(let n) = priority, n.isFinite, n.rounded() == n, (0...4).contains(n) else { throw TaskPageError("Choose priority P0–P4.") }
        }
        if let review = details.extra["omegaReview"], case .bool = review {} else if details.extra["omegaReview"] != nil { throw TaskPageError("Invalid review state.") }
        if let raw = details.extra["omegaDependencies"] {
            guard case .array(let values) = raw, values.count <= 32 else { throw TaskPageError("Use at most 32 dependencies.") }
            var seen = Set<String>()
            for value in values {
                guard case .object(let record) = value, Set(record.keys).isSubset(of: ["id", "path"]), let id = string(record["id"]), id.range(of: "^[A-Za-z0-9_-]{1,80}$", options: .regularExpression) != nil else { throw TaskPageError("Invalid dependency identity.") }
                let path = string(record["path"]) ?? ""
                guard (record["path"] == nil || string(record["path"]) != nil), path.utf16.count <= 2000, !path.hasPrefix("/"), !path.contains("\0"), !path.contains("\\"), seen.insert(path + "#" + id).inserted else { throw TaskPageError("Invalid or duplicate dependency.") }
            }
        }
        if let value = details.extra["omegaClaim"] {
            guard case .object(let record) = value, ["owner", "token", "at"].allSatisfy({ key in
                guard let s = string(record[key]) else { return false }; return !s.isEmpty && s.utf16.count <= 200 && !s.contains("\0")
            }) else { throw TaskPageError("Invalid task claim.") }
        }
    }
    struct Graph {
        let byID: [String: [TaskReference]]
        let cyclic: Set<String>
        let completed: String
        let firstOpen: String?
        init(_ document: TaskDocument) {
            completed = document.completedStatus
            firstOpen = document.statuses.first { $0 != document.completedStatus }
            let lookup = Dictionary(grouping: document.references.filter { $0.kind != "goal" && $0.details.id != nil }, by: { $0.details.id! })
            byID = lookup
            var remaining: [String: Int] = [:], dependents: [String: [String]] = [:]
            for (id, refs) in lookup {
                let edges = refs.flatMap { dependencies($0.details) }.compactMap { dep -> String? in
                    guard dep["path"] == nil, let target = string(dep["id"]), lookup[target] != nil else { return nil }; return target
                }
                remaining[id] = edges.count
                for target in edges { dependents[target, default: []].append(id) }
            }
            var queue = remaining.filter { $0.value == 0 }.map(\.key), index = 0
            while index < queue.count {
                for id in dependents[queue[index]] ?? [] { remaining[id]! -= 1; if remaining[id] == 0 { queue.append(id) } }
                index += 1
            }
            cyclic = Set(remaining.filter { $0.value > 0 }.map(\.key))
        }
        func state(_ ref: TaskReference) -> String {
            if ref.details.draft == true { return "draft" }
            if ref.status == completed { return "done" }
            if let id = ref.details.id, cyclic.contains(id) { return "blocked" }
            if !text(ref.details, "omegaBlocker").isEmpty || dependencies(ref.details).contains(where: { dep in
                guard dep["path"] == nil, let id = string(dep["id"]), let targets = byID[id], targets.count == 1 else { return true }
                return targets[0].status != completed
            }) { return "blocked" }
            if ref.details.extra["omegaReview"] == .bool(true) { return "review" }
            if claim(ref.details) != nil { return "claimed" }
            if !text(ref.details, "omegaAssignee").isEmpty { return "assigned" }
            return ref.status == firstOpen ? "ready" : "working"
        }
    }
    static func state(_ ref: TaskReference, in document: TaskDocument) -> String { Graph(document).state(ref) }
    static func rejectCycles(_ document: TaskDocument) throws {
        guard Graph(document).cyclic.isEmpty else { throw TaskPageError("That dependency would create a loop.") }
    }

}

extension TaskDocument {
    mutating func updateDetails(_ reference: String, _ change: (inout TaskDetails) throws -> Void) throws {
        guard references.contains(where: { $0.reference == reference && $0.kind != "goal" }) else { throw TaskPageError("Task no longer exists. Read it again.") }
        let path = reference.dropFirst(2).split(separator: ".").map { Int($0)! }
        if path.count == 1 { try change(&tasks[path[0]].details) }
        else { try tasks[path[0]].subtasks[path[1]].update(at: path.dropFirst(2)) { try change(&$0.details) } }
    }
}
