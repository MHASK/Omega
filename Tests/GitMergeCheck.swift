import Foundation
@main struct GitMergeCheck {
    static func main() throws {
        func document(_ base: String, _ current: String, _ incoming: String) throws -> GitMergeDocument {
            try GitMergeDocument.make(GitReview(path: "Plan.md", mine: Data(current.utf8), incoming: Data(incoming.utf8), base: Data(base.utf8), checkpointPath: nil))
        }
        func check(_ condition: Bool, _ title: String) throws { guard condition else { throw GitFailure(title) }; print("PASS: " + title) }
        let base = "# Plan\n\nShip Monday.\n\n" + (1...12).map { "Context \($0)\n" }.joined() + "Budget 10.\n"
        let current = base.replacingOccurrences(of: "Monday", with: "Tuesday").replacingOccurrences(of: "Budget 10", with: "Budget 12")
        let incoming = base.replacingOccurrences(of: "Monday", with: "Friday").replacingOccurrences(of: "Budget 10", with: "Budget 15")
        let merge = try document(base,current,incoming), conflicts = merge.parts.filter { $0.common == nil }
        try check(merge.conflicts == 2 && conflicts[0].current == "Ship Tuesday.\n" && conflicts[1].incoming == "Budget 15.\n", "Git identifies separate conflicts and exact source lines")
        let result = merge.parts.map { $0.common ?? $0.incoming! }.joined()
        try check(result == incoming && merge.patch.contains("@@") && merge.patch.contains("-Ship Tuesday.") && merge.patch.contains("+Ship Friday."), "real Git diff and per-hunk composition retain the entire document")
        let clean = try document("A\nB\nC\nD\nE\n", "AA\nB\nC\nD\nE\n", "A\nB\nC\nD\nEE\n")
        try check(clean.conflicts == 0 && clean.parts.first?.common == "AA\nB\nC\nD\nEE\n", "non-overlapping changes are already combined in the result")
        let noEOF = try document("Old", "Mine", "Theirs")
        try check(noEOF.parts[0].current == "Mine" && noEOF.parts[0].incoming == "Theirs", "no final newline is preserved")
        let unicode = try document("Hello 👋\n", "Hello ലോകം 👋\n", "Hello 世界 👋\n")
        try check(unicode.parts[0].current == "Hello ലോകം 👋\n", "Unicode remains exact")
        let markers = try document("<<<<<<< Current\nA\n", "<<<<<<< Current\nB\n", "<<<<<<< Current\nC\n")
        try check(markers.parts.map { $0.common ?? $0.current! }.joined() == "<<<<<<< Current\nB\n", "literal marker text in a note is preserved")
        let deleted = try GitMergeDocument.make(GitReview(path:"Plan.md",mine:nil,incoming:Data("Keep".utf8),base:Data("Old".utf8),checkpointPath:nil))
        try check(deleted.currentDeleted && deleted.conflicts == 1, "deletion remains a file-level choice")
        if CommandLine.arguments.count > 1 { try JSONEncoder().encode(merge).write(to: URL(fileURLWithPath:CommandLine.arguments[1])) }
    }
}
