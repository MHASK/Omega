import Foundation

// Ask Git for both the diff and the three-way merge. The review never changes
// the checkout, and it uses exact bytes from the saved local/incoming commits.
struct GitMergeDocument: Codable {
    struct Part: Codable {
        var common: String?
        var current: String?
        var incoming: String?
        var base: String?
    }
    let path: String
    let current: String
    let incoming: String
    let original: String
    let currentDeleted: Bool
    let incomingDeleted: Bool
    let patch: String
    let parts: [Part]
    var conflicts: Int { parts.filter { $0.common == nil }.count }
    static func make(_ review: GitReview) throws -> GitMergeDocument {
        let current = String(data: review.mine ?? Data(), encoding: .utf8) ?? ""
        let incoming = String(data: review.incoming ?? Data(), encoding: .utf8) ?? ""
        let original = String(data: review.base ?? Data(), encoding: .utf8) ?? ""
        let fm = FileManager.default, temp = fm.temporaryDirectory.appendingPathComponent("OmegaDiff-" + UUID().uuidString)
        try fm.createDirectory(at: temp, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? fm.removeItem(at: temp) }
        for (name, text) in [("current", current), ("incoming", incoming), ("original", original)] {
            try Data(text.utf8).write(to: temp.appendingPathComponent(name))
        }
        let git = GitRunner(timeout: 20)
        let diff = try git.git(["diff", "--no-index", "--no-ext-diff", "--no-textconv", "--no-color", "--text", "--unified=4", "--", "current", "incoming"], at: temp, allowFailure: true)
        guard diff.status == 0 || diff.status == 1 else { throw GitFailure("The comparison could not be prepared. Both copies are safe.") }
        var parts: [Part] = []
        if review.mine == nil || review.incoming == nil {
            // Delete/modify is a file-level decision, even if text would merge.
            parts = [Part(current: current, incoming: incoming, base: original)]
        } else {
            var size = 32
            while [current, incoming, original].contains(where: { $0.contains(String(repeating: "<", count: size)) || $0.contains(String(repeating: "|", count: size)) || $0.contains(String(repeating: "=", count: size)) || $0.contains(String(repeating: ">", count: size)) }) { size += 1 }
            let merged = try git.git(["merge-file", "--stdout", "--diff3", "--marker-size=\(size)", "-L", "Current", "-L", "Original", "-L", "Incoming", "current", "original", "incoming"], at: temp, allowFailure: true)
            guard merged.status >= 0 && merged.status < 128 else { throw GitFailure("This file needs a whole-file choice. Both copies are safe.") }
            if merged.status == 0 { parts = [Part(common: merged.text)] }
            else { parts = try parse(merged.text, size: size, current: current, incoming: incoming, original: original) }
        }
        return GitMergeDocument(path: review.path, current: current, incoming: incoming, original: original, currentDeleted: review.mine == nil, incomingDeleted: review.incoming == nil, patch: diff.text, parts: parts)
    }
    private static func parse(_ text: String, size: Int, current: String, incoming: String, original: String) throws -> [Part] {
        let start = String(repeating: "<", count: size) + " Current\n", base = String(repeating: "|", count: size) + " Original\n"
        let divider = String(repeating: "=", count: size) + "\n", end = String(repeating: ">", count: size) + " Incoming\n"
        var result: [Part] = [], cursor = text.startIndex
        while let opening = text.range(of: start, range: cursor..<text.endIndex) {
            if cursor < opening.lowerBound { result.append(Part(common: String(text[cursor..<opening.lowerBound]))) }
            guard let ancestor = text.range(of: base, range: opening.upperBound..<text.endIndex),
                  let middle = text.range(of: divider, range: ancestor.upperBound..<text.endIndex),
                  let closing = text.range(of: end, range: middle.upperBound..<text.endIndex) else { throw GitFailure("This comparison could not be read safely.") }
            var a = String(text[opening.upperBound..<ancestor.lowerBound]), b = String(text[middle.upperBound..<closing.lowerBound]), c = String(text[ancestor.upperBound..<middle.lowerBound])
            if closing.upperBound == text.endIndex {
                if !current.hasSuffix("\n"), a.hasSuffix("\n") { a.removeLast() }
                if !incoming.hasSuffix("\n"), b.hasSuffix("\n") { b.removeLast() }
                if !original.hasSuffix("\n"), c.hasSuffix("\n") { c.removeLast() }
            }
            result.append(Part(current: a, incoming: b, base: c)); cursor = closing.upperBound
        }
        if cursor < text.endIndex { result.append(Part(common: String(text[cursor...]))) }
        guard result.contains(where: { $0.common == nil }) else { throw GitFailure("The conflicting lines could not be located safely.") }
        return result
    }
}
