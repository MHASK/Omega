import Foundation

struct NoteChecklistItem: Identifiable, Equatable {
    let title: String
    let completed: Bool
    let depth: Int
    let offset: Int
    var reference: String? = nil
    var id: String { reference ?? String(offset) }
}

enum NoteChecklist {
    private static let item = try! NSRegularExpression(pattern: #"^([ \t]*)(?:[-+*]|[0-9]+[.)])[ \t]+\[([ xX])\][ \t]+(.+?)\s*$"#)
    private static let list = try! NSRegularExpression(pattern: #"^([ \t]*)(?:[-+*]|[0-9]+[.)])[ \t]+"#)
    private static let fence = try! NSRegularExpression(pattern: #"^[ \t]*(?:>[ \t]*)*(`{3,}|~{3,})(.*)$"#)
    static func items(in source: String) -> [NoteChecklistItem] {
        if TaskDocument.isTaskPage(source) {
            guard let doc = try? TaskDocument(markdown: source) else { return [] }
            return doc.references.filter { $0.kind != "goal" && $0.details.draft != true }.map {
                NoteChecklistItem(title: $0.title, completed: $0.status == doc.completedStatus,
                                  depth: $0.reference.filter { $0 == "." }.count, offset: 0, reference: $0.reference)
            }
        }
        var result: [NoteChecklistItem] = [], offset = 0, fenceChar: Character?, fenceLength = 0
        var comment = false, frontmatter = false, htmlBlock = false, parents: [Int] = []
        for (number, raw) in source.components(separatedBy: "\n").enumerated() {
            defer { offset += raw.utf16.count + 1 }
            let line = raw.replacingOccurrences(of: "\r", with: ""), ns = line as NSString
            let range = NSRange(location: 0, length: ns.length), trimmed = line.trimmingCharacters(in: .whitespaces)
            if number == 0 && trimmed == "---" { frontmatter = true; continue }
            if frontmatter { if trimmed == "---" || trimmed == "..." { frontmatter = false }; continue }
            if comment { if line.contains("-->") { comment = false }; continue }
            if let match = fence.firstMatch(in: line, range: range) {
                let marker = ns.substring(with: match.range(at: 1))
                if fenceChar == nil {
                    if !line.hasPrefix("    ") && !line.hasPrefix("\t") { parents = [] }
                    fenceChar = marker.first; fenceLength = marker.count
                }
                else if marker.first == fenceChar && marker.count >= fenceLength && ns.substring(with: match.range(at: 2)).trimmingCharacters(in: .whitespaces).isEmpty { fenceChar = nil }
                continue
            }
            if fenceChar != nil { continue }
            if line.contains("<!--") {
                comment = line.range(of: "<!--", options: .backwards)!.lowerBound > (line.range(of: "-->", options: .backwards)?.lowerBound ?? line.startIndex) || !line.contains("-->")
                if trimmed.hasPrefix("<!--") || comment { continue }
            }
            if htmlBlock { if trimmed.isEmpty { htmlBlock = false }; continue }
            if trimmed.range(of: #"^</?[A-Za-z][^>]*>"#, options: .regularExpression) != nil { htmlBlock = true; continue }
            guard let marker = list.firstMatch(in: line, range: range) else {
                if !trimmed.isEmpty && !line.hasPrefix(" ") && !line.hasPrefix("\t") { parents = [] }
                continue
            }
            let indent = ns.substring(with: marker.range(at: 1)).reduce(0) { $0 + ($1 == "\t" ? 4 : 1) }
            parents.removeAll { $0 >= indent }
            // Four-space standalone examples are code, while indented children
            // of an actual list retain their checklist identity.
            guard indent < 4 || parents.last.map({ indent <= $0 + 4 }) == true else { continue }
            let depth = parents.count; parents.append(indent)
            guard let match = item.firstMatch(in: line, range: range) else { continue }
            let title = ns.substring(with: match.range(at: 3))
            result.append(NoteChecklistItem(title: title, completed: ns.substring(with: match.range(at: 2)).lowercased() == "x",
                                            depth: depth, offset: offset + match.range(at: 2).location))
        }
        return result
    }
    static func toggled(_ item: NoteChecklistItem, in current: String, expected: String) throws -> String {
        guard current == expected, items(in: current).contains(item), item.reference == nil else {
            throw TaskPageError("This note changed. The list has been refreshed; try the checkbox again.")
        }
        return (current as NSString).replacingCharacters(in: NSRange(location: item.offset, length: 1), with: item.completed ? " " : "x")
    }
}

struct ChecklistGroup: Identifiable, Equatable {
    let url: URL
    let source: String
    let items: [NoteChecklistItem]
    var id: String { url.path }
}
