import Foundation

enum NoteLinks {
    static func href(from source: URL, to target: URL) -> String {
        var from = source.deletingLastPathComponent().standardizedFileURL.pathComponents
        var to = target.standardizedFileURL.pathComponents
        while !from.isEmpty && from.first == to.first { from.removeFirst(); to.removeFirst() }
        let path = (Array(repeating: "..", count: from.count) + to).joined(separator: "/")
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "?#()[]<>\\\"%:")
        let encoded = path.addingPercentEncoding(withAllowedCharacters: allowed) ?? path
        return encoded.hasPrefix("../") ? encoded : "./" + encoded
    }

    static func resolve(_ href: String, from source: URL, roots: [URL]) -> URL? {
        guard !href.hasPrefix("//"), let parts = URLComponents(string: href), parts.scheme == nil,
              let path = parts.percentEncodedPath.removingPercentEncoding, !path.isEmpty else { return nil }
        // Normalize dot segments lexically first. Foundation's standardization
        // can resolve symlinks along a path containing '..' before validation.
        var components = path.hasPrefix("/") ? ["/"] : source.deletingLastPathComponent().pathComponents
        for component in path.split(separator: "/").map(String.init) {
            if component == "." { continue }
            if component == ".." { if components.count > 1 { components.removeLast() } }
            else { components.append(component) }
        }
        let url = URL(fileURLWithPath: NSString.path(withComponents: components))
        guard NoteFiles.extensions.contains(url.pathExtension.lowercased()),
              roots.contains(where: { url.path.hasPrefix($0.standardizedFileURL.path + "/") }),
              url.resolvingSymlinksInPath().path == url.path,
              !url.pathComponents.contains(where: { $0.hasPrefix(".") }),
              (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else { return nil }
        return url
    }
}

struct NoteEntry: Identifiable, Equatable {
    let url: URL
    let isFolder: Bool
    var children: [NoteEntry] = []
    var isTaskPage = false
    var id: String { url.path }
    var name: String { isFolder ? url.lastPathComponent : url.deletingPathExtension().lastPathComponent }
}

enum NoteFiles {
    static let extensions = ["md", "markdown", "txt"]

    static func scan(_ root: URL, depth: Int = 0) throws -> [NoteEntry] {
        guard depth < 24 else { return [] }
        let urls = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey], options: [.skipsHiddenFiles])
        return try urls.compactMap { url -> NoteEntry? in
            let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard values.isSymbolicLink != true else { return nil }
            // Foundation may enumerate /var through its /private/var alias.
            // Keep item identities in the spelling of the open notebook root.
            let url = root.appendingPathComponent(url.lastPathComponent, isDirectory: values.isDirectory == true)
            if values.isDirectory == true {
                return NoteEntry(url: url, isFolder: true, children: (try? scan(url, depth: depth + 1)) ?? [])
            }
            guard extensions.contains(url.pathExtension.lowercased()) else { return nil }
            var taskPage = false
            if let handle = try? FileHandle(forReadingFrom: url) {
                defer { try? handle.close() }
                if let data = try? handle.read(upToCount: 4096) { taskPage = TaskDocument.isTaskPage(String(decoding: data, as: UTF8.self)) }
            }
            return NoteEntry(url: url, isFolder: false, isTaskPage: taskPage)
        }.sorted {
            if $0.isFolder != $1.isFolder { return $0.isFolder }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    static func flatten(_ entries: [NoteEntry]) -> [NoteEntry] {
        entries.flatMap { [$0] + flatten($0.children) }
    }

    static func uniqueURL(in folder: URL, name: String = "Untitled", ext: String = "md") -> URL {
        var url = folder.appendingPathComponent(name).appendingPathExtension(ext)
        var count = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = folder.appendingPathComponent("\(name) \(count)").appendingPathExtension(ext)
            count += 1
        }
        return url
    }

    static func validName(_ name: String) -> Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !name.contains("/") && !name.contains(":") && name.rangeOfCharacter(from: .controlCharacters) == nil && !name.hasPrefix(".")
    }

    // Keep ordinary relative Markdown links valid when a note or folder moves.
    // Fenced and inline code are excluded so examples remain literal.
    static func rebaseLinks(_ text: String, from oldFile: URL, to newFile: URL, moving oldRoot: URL, to newRoot: URL) -> String {
        let source = text as NSString
        let full = NSRange(location: 0, length: source.length)
        let codePattern = #"(?m)^\s*(`{3,}|~{3,})[^\n]*\n[\s\S]*?^\s*\1[^\n]*(?:\n|$)|(`+)[^`\n]*\2"#
        let code = (try? NSRegularExpression(pattern: codePattern))?.matches(in: text, range: full).map(\.range) ?? []
        let pattern = #"(?:!?\[[^\]\n]*\]\([ \t]*|(?m:^[ \t]{0,3}\[(?!\^)[^\]\n]+\]:[ \t]*))(<[^>\n]+>|[^\s\)]+)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return text }
        let result = NSMutableString(string: text)
        for match in regex.matches(in: text, range: full).reversed() {
            guard !code.contains(where: { NSIntersectionRange($0, match.range).length > 0 }) else { continue }
            let token = source.substring(with: match.range(at: 1))
            let angled = token.hasPrefix("<") && token.hasSuffix(">")
            let raw = angled ? String(token.dropFirst().dropLast()) : token
            guard !raw.hasPrefix("/"), !raw.hasPrefix("#"), !raw.isEmpty,
                  raw.range(of: #"^[A-Za-z][A-Za-z0-9+.-]*:"#, options: .regularExpression) == nil else { continue }
            let suffixAt = raw.firstIndex(where: { $0 == "#" || $0 == "?" }) ?? raw.endIndex
            let suffix = String(raw[suffixAt...])
            let path = String(raw[..<suffixAt]).removingPercentEncoding ?? String(raw[..<suffixAt])
            guard !path.isEmpty else { continue }
            var destination = oldFile.deletingLastPathComponent().appendingPathComponent(path).standardizedFileURL
            if destination.path == oldRoot.path || destination.path.hasPrefix(oldRoot.path + "/") {
                destination = URL(fileURLWithPath: newRoot.path + String(destination.path.dropFirst(oldRoot.path.count)))
            }
            // Preserve spelling (./, percent escapes, etc.) when a relative
            // link already resolves correctly at the new location.
            if newFile.deletingLastPathComponent().appendingPathComponent(path).standardizedFileURL == destination { continue }
            var originParts = newFile.deletingLastPathComponent().standardizedFileURL.pathComponents
            var targetParts = destination.pathComponents
            while !originParts.isEmpty && !targetParts.isEmpty && originParts.first == targetParts.first { originParts.removeFirst(); targetParts.removeFirst() }
            let relative = (Array(repeating: "..", count: originParts.count) + targetParts).joined(separator: "/")
            var allowed = CharacterSet.urlPathAllowed
            allowed.remove(charactersIn: "?#()[]<>\\\"%")
            let encoded = (relative.addingPercentEncoding(withAllowedCharacters: allowed) ?? relative) + suffix
            let replacement = angled ? "<" + encoded + ">" : encoded
            result.replaceCharacters(in: match.range(at: 1), with: replacement)
        }
        return result as String
    }

    static func wordCount(_ text: String) -> Int {
        text.split(whereSeparator: { $0.isWhitespace }).filter { $0.contains(where: { $0.isLetter || $0.isNumber }) }.count
    }
}

struct TaskPreferences: Codable, Equatable {
    var statuses = ["To do", "In progress", "Done"]
    var completed = "Done"
    func validate() throws {
        guard !statuses.isEmpty, statuses.count <= 12, Set(statuses.map { $0.lowercased() }).count == statuses.count,
              statuses.allSatisfy({ !$0.isEmpty && $0.utf16.count <= 40 && $0 == $0.trimmingCharacters(in: .whitespacesAndNewlines) && !$0.contains(where: { "\n\r<>#".contains($0) }) && $0.lowercased() != "goals" }), statuses.contains(completed)
        else { throw TaskPageError("Use 1–12 unique status names and choose a completed status. ‘Goals’ is reserved.") }
    }
}
struct TaskPageError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}
struct TaskDetails: Codable {
    var id: String?
    var description: String?
    var due: String?
    var labels: [String]?
    var status: String?
    var draft: Bool?
    var goals: [String]?
    var extra: [String: TaskJSON] = [:]
    var isEmpty: Bool { id == nil && description == nil && due == nil && labels == nil && status == nil && draft == nil && goals == nil && extra.isEmpty }
    func validate(child: Bool) throws {
        try TaskCoordination.validate(self)
        if let id, id.range(of: "^[A-Za-z0-9_-]{1,80}$", options: .regularExpression) == nil { throw TaskPageError("Invalid task identity.") }
        if let description, description.utf16.count > 100_000 { throw TaskPageError("Task descriptions are limited to 100,000 characters.") }
        if let due {
            let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.calendar = Calendar(identifier: .gregorian); formatter.dateFormat = "yyyy-MM-dd"; formatter.isLenient = false
            guard due.count == 10, let date = formatter.date(from: due), formatter.string(from: date) == due else { throw TaskPageError("Use a valid due date in YYYY-MM-DD format.") }
        }
        if let labels, labels.count > 12 || labels.contains(where: { $0.trimmingCharacters(in: .whitespaces).isEmpty || $0.utf16.count > 40 || $0.contains("\n") || $0.contains("\r") }) { throw TaskPageError("Use at most 12 labels of 1–40 characters.") }
        if let goals, goals.count > 32 || Set(goals).count != goals.count || goals.contains(where: { $0.range(of: "^[A-Za-z0-9_-]{1,80}$", options: .regularExpression) == nil }) { throw TaskPageError("Use at most 32 unique goal identities.") }
        if let status {
            guard child else { throw TaskPageError("Main task statuses belong in the Markdown section heading.") }
            try TaskPreferences(statuses: [status], completed: status).validate()
        }
    }
    static func decode(_ json: String, child: Bool) throws -> TaskDetails {
        let data = Data(json.utf8)
        guard json.utf16.count <= 131_072, let object = try JSONSerialization.jsonObject(with: data) as? [String: Any], TaskJSON.safe(object) else { throw TaskPageError("Task metadata is too large, too deeply nested, or uses a number that cannot be preserved exactly.") }
        guard TaskJSON.uniqueKeys(json) else { throw TaskPageError("Task metadata repeats a JSON field. Keep one value for each field.") }
        let details = try JSONDecoder().decode(TaskDetails.self, from: data); try details.validate(child: child); return details
    }

    func markdown(child: Bool, depth: Int? = nil) -> String {
        guard !isEmpty else { return "" }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let json = String(decoding: try! encoder.encode(self), as: UTF8.self).replacingOccurrences(of: "<", with: "\\u003c").replacingOccurrences(of: ">", with: "\\u003e")
        return "\n" + String(repeating: "  ", count: (depth ?? (child ? 1 : 0)) + 1) + "<!-- folio:task " + json + " -->"
    }
}
// Preserve metadata owned by outside editors through every native mutation.
// This is also compiled on Linux; no Apple UI or persistence types belong here.
indirect enum TaskJSON: Codable, Equatable {
    case null, bool(Bool), number(Double), string(String), array([TaskJSON]), object([String: TaskJSON])
    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let v = try? c.decode(Bool.self) { self = .bool(v) }
        else if let v = try? c.decode(String.self) { self = .string(v) }
        else if let v = try? c.decode(Double.self) { self = .number(v) }
        else if let v = try? c.decode([TaskJSON].self) { self = .array(v) }
        else { self = .object(try c.decode([String: TaskJSON].self)) }
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case .bool(let v): try c.encode(v)
        case .number(let v): try c.encode(v)
        case .string(let v): try c.encode(v)
        case .array(let v): try c.encode(v)
        case .object(let v): try c.encode(v)
        }
    }
    private static let jsonTokens = try! NSRegularExpression(pattern: #""(?:\\.|[^"\\])*"|[{}\[\]:,]"#)
    static func uniqueKeys(_ json: String) -> Bool {
        let source = json as NSString
        let tokens = jsonTokens.matches(in: json, range: NSRange(location: 0, length: source.length)).map { source.substring(with: $0.range) }
        var stack: [Set<String>?] = []
        for (i, token) in tokens.enumerated() {
            if token == "{" { stack.append(Set<String>()) }
            else if token == "[" { stack.append(nil) }
            else if token == "}" || token == "]" { if !stack.isEmpty { stack.removeLast() } }
            else if token.hasPrefix("\""), i + 1 < tokens.count, tokens[i + 1] == ":", !stack.isEmpty, var keys = stack[stack.count - 1] {
                guard let key = try? JSONDecoder().decode(String.self, from: Data(token.utf8)), keys.insert(key).inserted else { return false }
                stack[stack.count - 1] = keys
            }
        }
        return true
    }
    static func safe(_ value: Any, depth: Int = 0) -> Bool {
        guard depth <= 16 else { return false }
        if value is NSNull || value is String { return true }
        if let n = value as? NSNumber { let v = n.doubleValue; return v.isFinite && (v.rounded() != v || abs(v) <= 9_007_199_254_740_991) }
        if let a = value as? [Any] { return a.allSatisfy { safe($0, depth: depth + 1) } }
        if let o = value as? [String: Any] { return o.values.allSatisfy { safe($0, depth: depth + 1) } }
        return false
    }
}
extension TaskDetails {
    private struct Key: CodingKey {
        let stringValue: String
        var intValue: Int? { nil }
        init(_ value: String) { stringValue = value }
        init?(stringValue: String) { self.init(stringValue) }
        init?(intValue: Int) { return nil }
    }
    static let knownKeys: Set<String> = ["id", "description", "due", "labels", "status", "draft", "goals"]
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Key.self)
        id = try c.decodeIfPresent(String.self, forKey: Key("id"))
        description = try c.decodeIfPresent(String.self, forKey: Key("description"))
        due = try c.decodeIfPresent(String.self, forKey: Key("due"))
        labels = try c.decodeIfPresent([String].self, forKey: Key("labels"))
        status = try c.decodeIfPresent(String.self, forKey: Key("status"))
        draft = try c.decodeIfPresent(Bool.self, forKey: Key("draft"))
        goals = try c.decodeIfPresent([String].self, forKey: Key("goals"))
        for key in c.allKeys where !Self.knownKeys.contains(key.stringValue) { extra[key.stringValue] = try c.decode(TaskJSON.self, forKey: key) }
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: Key.self)
        for (key, value) in extra where !Self.knownKeys.contains(key) { try c.encode(value, forKey: Key(key)) }
        try c.encodeIfPresent(id, forKey: Key("id")); try c.encodeIfPresent(description, forKey: Key("description"))
        try c.encodeIfPresent(due, forKey: Key("due")); try c.encodeIfPresent(labels, forKey: Key("labels"))
        try c.encodeIfPresent(status, forKey: Key("status")); try c.encodeIfPresent(draft, forKey: Key("draft")); try c.encodeIfPresent(goals, forKey: Key("goals"))
    }
}
struct TaskCheckItem: Codable {
    var title: String
    var completed = false
    var details = TaskDetails()
    var subtasks: [TaskCheckItem] = []
    mutating func update(at path: ArraySlice<Int>, _ change: (inout TaskCheckItem) throws -> Void) rethrows {
        if let index = path.first { try subtasks[index].update(at: path.dropFirst(), change) }
        else { try change(&self) }
    }
}
struct TaskPageItem: Codable {
    var title: String
    var status: String
    var subtasks: [TaskCheckItem] = []
    var details = TaskDetails()
}
struct TaskDocument: Codable {
    static let marker = "<!-- folio:tasks -->"
    static func isTaskPage(_ text: String) -> Bool {
        text.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "\u{FEFF}"))).hasPrefix(marker)
    }
    var title: String
    var statuses: [String]
    var completedStatus: String
    var goals: [TaskCheckItem] = []
    var tasks: [TaskPageItem] = []
    init(title: String = "Tasks", preferences: TaskPreferences = TaskPreferences()) {
        self.title = title; statuses = preferences.statuses; completedStatus = preferences.completed
    }
    init(markdown: String) throws {
        let text = markdown.hasPrefix("\u{FEFF}") ? String(markdown.dropFirst()) : markdown
        let lines = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n").components(separatedBy: "\n")
        let first = lines.firstIndex { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        guard let first, lines[first].trimmingCharacters(in: .whitespaces) == Self.marker else { throw TaskPageError("This note is not a task page.") }
        title = ""; statuses = []; completedStatus = "Done"
        var titleSeen = false, section: String?, seen = Set<String>(), path: [Int] = [], goalIndex: Int?, metadataSeen = false
        var index = first + 1
        while index < lines.count {
            let lineNumber = index + 1
            var line = lines[index]; index += 1
            do {
            if line.trimmingCharacters(in: .whitespaces).isEmpty { continue }
            if !titleSeen && line.hasPrefix("<!-- folio:completed ") && line.trimmingCharacters(in: .whitespaces).hasSuffix(" -->") {
                let json = String(line.trimmingCharacters(in: .whitespaces).dropFirst(21).dropLast(4))
                guard let value = try? JSONDecoder().decode(String.self, from: Data(json.utf8)) else { throw TaskPageError("Invalid completed-status marker.") }
                completedStatus = value; continue
            }
            if !titleSeen && line.hasPrefix("# ") { title = String(line.dropFirst(2)); titleSeen = true; continue }
            if titleSeen && line.hasPrefix("## ") {
                let name = String(line.dropFirst(3)); if name != "Goals" { try TaskPreferences(statuses: [name], completed: name).validate() }; guard seen.insert(name.lowercased()).inserted else { throw TaskPageError("Duplicate task section.") }
                section = name; path = []; goalIndex = nil; if name != "Goals" { statuses.append(name) }; continue
            }
            let spaces = line.prefix(while: { $0 == " " }).count, row = String(line.dropFirst(spaces)), depth = spaces / 2
            guard spaces % 2 == 0, depth <= 33 else { throw TaskPageError("Invalid task indentation.") }
            if row.range(of: #"^<!-- folio:task(?:\s|$)"#, options: .regularExpression) != nil {
                while !line.trimmingCharacters(in: .whitespaces).hasSuffix("-->") && index < lines.count && line.utf16.count <= 131_072 { line += "\n" + lines[index]; index += 1 }
                let row = String(line.dropFirst(spaces)).trimmingCharacters(in: .whitespaces)
                guard row.utf16.count <= 131_072, row.hasSuffix("-->"), !metadataSeen, depth == (goalIndex == nil ? path.count : 1), depth > 0 else { throw TaskPageError("Invalid task detail placement.") }
                // Keep valid external metadata on goals too. Goal progress
                // remains based on linked work or its checkbox, not this field.
                let details = try TaskDetails.decode(String(row.dropFirst(15).dropLast(3)).trimmingCharacters(in: .whitespacesAndNewlines), child: true)
                if let goalIndex { goals[goalIndex].details = details }
                else if path.count == 1 { tasks[path[0]].details = details }
                else { tasks[path[0]].subtasks[path[1]].update(at: path.dropFirst(2)) { $0.details = details } }
                metadataSeen = true; continue
            }
            guard titleSeen, let section, depth <= 32, (row.hasPrefix("- [") || row.hasPrefix("* [") || row.hasPrefix("+ [")), row.count >= 5 else { throw TaskPageError("This task page contains extra Markdown. Edit it in source view to preserve that content.") }
            let chars = Array(row); guard chars[4] == "]", [" ", "x", "X"].contains(String(chars[3])), chars.count == 5 || chars[5] == " " else { throw TaskPageError("Invalid task checkbox.") }
            let text = chars.count > 5 ? String(chars.dropFirst(6)) : "", checked = chars[3] != " "
            metadataSeen = false; goalIndex = nil
            if depth > 0 {
                guard section != "Goals", path.count >= depth else { throw TaskPageError("A subtask must follow a task.") }
                path = Array(path.prefix(depth)); var index = 0
                let child = TaskCheckItem(title: text, completed: checked)
                if depth == 1 { index = tasks[path[0]].subtasks.count; tasks[path[0]].subtasks.append(child) }
                else { tasks[path[0]].subtasks[path[1]].update(at: path.dropFirst(2)) { index = $0.subtasks.count; $0.subtasks.append(child) } }
                path.append(index)
            } else if section == "Goals" { goals.append(TaskCheckItem(title: text, completed: checked)); goalIndex = goals.count - 1; path = [] }
            else { tasks.append(TaskPageItem(title: text, status: section)); path = [tasks.count - 1] }
            } catch { throw TaskPageError("Line \(lineNumber): \(error is DecodingError ? "Invalid task metadata field type." : error.localizedDescription)") }
        }
        guard titleSeen else { throw TaskPageError("Task page needs a title.") }
        if statuses.isEmpty { statuses = TaskPreferences().statuses }
        if !statuses.contains(completedStatus) { statuses.append(completedStatus) }
        var ids = Set<String>()
        for ref in references {
            if let id = ref.details.id, !ids.insert(id).inserted { throw TaskPageError("Duplicate task identity.") }
            if ref.kind != "goal", let status = ref.details.status, !statuses.contains(status) { statuses.append(status) }
        }
        try TaskPreferences(statuses: statuses, completed: completedStatus).validate()
        for index in tasks.indices {
            if let status = tasks[index].details.status {
                tasks[index].status = status
                tasks[index].details.status = nil
            }
        }
    }
    func status(of child: TaskCheckItem) -> String { child.details.status ?? (child.completed ? completedStatus : (statuses.first(where: { $0 != completedStatus }) ?? completedStatus)) }
    static func line(_ value: String) -> String { value.replacingOccurrences(of: "\r", with: " ").replacingOccurrences(of: "\n", with: " ") }
    var markdown: String {
        func check(_ title: String, _ completed: Bool) -> String { "- [\(completed ? "x" : " ")] " + Self.line(title) }
        func childRow(_ item: TaskCheckItem, _ depth: Int) -> String {
            String(repeating: "  ", count: depth) + check(item.title, self.status(of: item) == completedStatus) + item.details.markdown(child: true, depth: depth) + item.subtasks.map { "\n" + childRow($0, depth + 1) }.joined()
        }
        var result = Self.marker + "\n"
        if completedStatus != "Done" { result += "<!-- folio:completed " + String(decoding: try! JSONEncoder().encode(completedStatus), as: UTF8.self) + " -->\n" }
        result += "# " + Self.line(title) + "\n\n## Goals\n\n" + goals.map { check($0.title, goalProgress($0).done) + $0.details.markdown(child: false) }.joined(separator: "\n")
        for status in statuses {
            result += "\n\n## " + status + "\n\n" + tasks.filter { $0.status == status }.map { task in
                ([check(task.title, status == completedStatus) + task.details.markdown(child: false)] + task.subtasks.map { childRow($0, 1) }).joined(separator: "\n")
            }.joined(separator: "\n")
        }
        return result.trimmingCharacters(in: .newlines) + "\n"
    }
    mutating func configure(_ preferences: TaskPreferences, renames: [String: String] = [:]) throws {
        try preferences.validate()
        var changed = tasks
        for i in changed.indices {
            let old = changed[i].status
            changed[i].status = renames[old] ?? old
            if old == completedStatus { changed[i].status = preferences.completed }
            guard preferences.statuses.contains(changed[i].status) else { throw TaskPageError("Move tasks out of ‘\(old)’ before removing that status.") }
            func configureChild(_ item: inout TaskCheckItem) throws {
                let old = status(of: item), next = old == completedStatus ? preferences.completed : renames[old] ?? old
                guard preferences.statuses.contains(next) else { throw TaskPageError("Move subtasks out of ‘\(old)’ before removing that status.") }
                item.details.status = next; item.completed = next == preferences.completed
                for j in item.subtasks.indices { try configureChild(&item.subtasks[j]) }
            }
            for j in changed[i].subtasks.indices { try configureChild(&changed[i].subtasks[j]) }
        }
        statuses = preferences.statuses; completedStatus = preferences.completed; tasks = changed
    }
}

struct TaskReference {
    let reference: String
    let kind: String
    let title: String
    let parent: String
    let details: TaskDetails
    var status: String? = nil
}
extension TaskDocument {
    var references: [TaskReference] {
        var result = goals.enumerated().map { TaskReference(reference: "g:\($0.offset)", kind: "goal", title: $0.element.title, parent: title, details: $0.element.details) }
        func children(_ items: [TaskCheckItem], _ path: String, _ parent: String) {
            for (index, child) in items.enumerated() {
                let ref = path + ".\(index)"
                result.append(TaskReference(reference: ref, kind: "subtask", title: child.title, parent: parent, details: child.details, status: status(of: child)))
                children(child.subtasks, ref, child.title)
            }
        }
        for (index, task) in tasks.enumerated() {
            let ref = "t:\(index)"
            result.append(TaskReference(reference: ref, kind: "task", title: task.title, parent: title, details: task.details, status: task.status))
            children(task.subtasks, ref, task.title)
        }
        return result
    }
    func goalProgress(_ goal: TaskCheckItem) -> (linked: [TaskReference], completed: Int, done: Bool) {
        let linked = references.filter { $0.kind != "goal" && goal.details.id != nil && ($0.details.goals ?? []).contains(goal.details.id ?? "") }
        let completed = linked.filter { $0.status == completedStatus }.count
        return (linked, completed, linked.isEmpty ? goal.completed : completed == linked.count)
    }
    mutating func setTaskGoals(_ reference: String, goals goalReferences: [String]) throws {
        guard goalReferences.count <= 32, Set(goalReferences).count == goalReferences.count,
              references.contains(where: { $0.reference == reference && $0.kind != "goal" }),
              goalReferences.allSatisfy({ value in references.contains { $0.reference == value && $0.kind == "goal" } }) else { throw TaskPageError("Choose a task and goals from this task page.") }
        let ids = try goalReferences.map { try ensureLinkID($0) }
        _ = try ensureLinkID(reference)
        let path = reference.dropFirst(2).split(separator: ".").map { Int($0)! }
        if path.count == 1 { tasks[path[0]].details.goals = ids.isEmpty ? nil : ids }
        else { tasks[path[0]].subtasks[path[1]].update(at: path.dropFirst(2)) { $0.details.goals = ids.isEmpty ? nil : ids } }
    }
    mutating func removeGoal(at index: Int) {
        let id = goals.remove(at: index).details.id
        guard let id else { return }
        func clear(_ details: inout TaskDetails) {
            guard let values = details.goals else { return }
            let next = values.filter { $0 != id }; details.goals = next.isEmpty ? nil : next
        }
        func children(_ items: inout [TaskCheckItem]) {
            for i in items.indices { clear(&items[i].details); children(&items[i].subtasks) }
        }
        for i in tasks.indices { clear(&tasks[i].details); children(&tasks[i].subtasks) }
    }
    mutating func ensureLinkID(_ reference: String) throws -> String {
        guard let ref = references.first(where: { $0.reference == reference }) else { throw TaskPageError("This item changed. Choose it again.") }
        if let id = ref.details.id { return id }
        let id = UUID().uuidString.lowercased()
        if ref.kind == "goal" { goals[Int(reference.dropFirst(2))!].details.id = id }
        else {
            let path = reference.dropFirst(2).split(separator: ".").map { Int($0)! }
            if path.count == 1 { tasks[path[0]].details.id = id }
            else { tasks[path[0]].subtasks[path[1]].update(at: path.dropFirst(2)) { $0.details.id = id } }
        }
        return id
    }
    mutating func moveTask(id: String, parentID: String?) throws {
        guard let source = references.first(where: { $0.details.id == id && $0.kind != "goal" }),
              parentID != id else { throw TaskPageError("Choose a task and a different parent.") }
        let destination = parentID.flatMap { value in references.first { $0.details.id == value && $0.kind != "goal" } }
        guard parentID == nil || destination != nil else { throw TaskPageError("The parent task is no longer available.") }
        if let destination, destination.details.draft == true || destination.reference.hasPrefix(source.reference + ".") { throw TaskPageError("A task cannot be moved under one of its own subtasks or a draft.") }
        let path = source.reference.dropFirst(2).split(separator: ".").map { Int($0)! }
        var item: TaskCheckItem
        if path.count == 1 { let main = tasks[path[0]]; var details = main.details; details.status = main.status; item = TaskCheckItem(title: main.title, completed: main.status == completedStatus, details: details, subtasks: main.subtasks) }
        else {
            var found: TaskCheckItem?
            tasks[path[0]].subtasks[path[1]].update(at: path.dropFirst(2)) { found = $0 }
            item = found!; item.details.status = status(of: item)
        }
        func height(_ value: TaskCheckItem) -> Int { 1 + (value.subtasks.map(height).max() ?? 0) }
        let depth = destination.map { $0.reference.split(separator: ".").count } ?? 0
        guard depth + height(item) <= 33 else { throw TaskPageError("This move would nest tasks too deeply.") }
        if path.count == 1 { tasks.remove(at: path[0]) }
        else if path.count == 2 { tasks[path[0]].subtasks.remove(at: path[1]) }
        else { tasks[path[0]].subtasks[path[1]].update(at: path.dropFirst(2).dropLast()) { $0.subtasks.remove(at: path.last!) } }
        if let parentID {
            let next = references.first { $0.details.id == parentID }!
            let target = next.reference.dropFirst(2).split(separator: ".").map { Int($0)! }
            if target.count == 1 { tasks[target[0]].subtasks.append(item) }
            else { tasks[target[0]].subtasks[target[1]].update(at: target.dropFirst(2)) { $0.subtasks.append(item) } }
        } else {
            let value = status(of: item); item.details.status = nil
            tasks.append(TaskPageItem(title: item.title, status: value, subtasks: item.subtasks, details: item.details))
        }
    }
}
