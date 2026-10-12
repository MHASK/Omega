import Foundation

func runSearchTests() throws {
    let table = NoteSearchIndex.clean("| Idea | Status |\n| :--- | ---: |\n| Morning pages | **In progress** |")
    precondition(table == "Idea · Status Morning pages · In progress", table)
    precondition(NoteSearchIndex.clean("### Title\n\n- [x] **Bold** and _italic_ [label](https://example.com) with `foo_bar` &amp; more") == "Title Bold and italic label with foo_bar & more")
    let preview = NoteSearchIndex.excerpt(String(repeating: "irrelevant words ", count: 20) + "the lavender suitcase is ready " + String(repeating: "more words ", count: 20), terms: ["lavender"])
    precondition(preview.hasPrefix("… ") && preview.hasSuffix(" …") && preview.contains("lavender") && preview.count < 100)
    let parent = FileManager.default.temporaryDirectory.appendingPathComponent("Folio-search-" + UUID().uuidString)
    let book = parent.appendingPathComponent("First"), other = parent.appendingPathComponent("Second")
    try FileManager.default.createDirectory(at: book, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: parent) }
    func write(_ name: String, _ text: String, in folder: URL? = nil) throws -> URL {
        let file = (folder ?? book).appendingPathComponent(name + ".md")
        try text.write(to: file, atomically: true, encoding: .utf8)
        return file
    }
    let launch = try write("Launch plan", "# Launch checklist\n\nRelease the sample update on Friday.\n\nThe deployment budget is 500 credits.")
    let journal = try write("Journal", "# Thoughts\n\nA completely unrelated paragraph about a forest.\n\n" + String(repeating: "A quiet morning in the forest. ", count: 100) + "\n\n## Coffee\n\nCafé in Zürich. 日本語のメモ.\n\n## Travel details\n\nThe lavender suitcase holds the passport for Kyoto.")
    let duplicate = try write("Journal", "# Garden\n\nLavender flowers bloom in the garden.", in: other)
    let empty = try write("Empty", "")
    let index = NoteSearchIndex()
    index.refresh(roots: [book, other])
    precondition(index.documents.count == 4)
    precondition(index.search("launch plan").first?.url == launch)
    precondition(index.search("where is the passport for Kyoto").first?.url == journal)
    let passage = index.search("passport Kyoto").first?.snippet ?? ""
    precondition(passage.contains("passport") && passage.contains("Kyoto") && passage.count < 100)
    precondition(index.search("lavender passport").first?.url == journal)
    precondition(index.search("deploymnet").first?.url == launch)
    precondition(index.search("deplo").first?.url == launch)
    precondition(index.search("CAFE zurich").first?.url == journal)
    precondition(index.search("日本語のメモ").first?.url == journal)
    precondition(index.search("Journal").count == 2)
    precondition(index.search("!!!").isEmpty && index.search("nonsenseword").isEmpty)
    precondition(index.search("", recent: [empty.path]).first?.url == empty)
    // A result carries the raw position of the same match shown in its excerpt.
    for query in ["passport Kyoto", "deploymnet", "deplo", "CAFE zurich", "日本語のメモ"] {
        let result = index.search(query).first!
        let anchor = result.anchor!
        let text = index.documents[result.url]!.source as NSString
        precondition(NoteSearchIndex.folded(text.substring(with: NSRange(location: anchor.location, length: anchor.length))) == anchor.term)
        if result.url == journal { precondition(anchor.location > 2500) }
    }
    precondition(index.search("Journal").allSatisfy { $0.anchor == nil })
    precondition(index.search("").allSatisfy { $0.anchor == nil })
    let repeated = "# Repeated words\n\nA harbor near the beginning.\n\n" + String(repeating: "Quiet water in the morning. ", count: 100) + "\n\nThe harbor destination is marked by a lighthouse."
    index.refresh(roots: [book, other], draft: (launch, repeated))
    let anchored = index.search("harbor destination lighthouse").first!
    precondition(anchored.url == launch && anchored.anchor!.location > 2500 && anchored.snippet.contains("destination"))
    index.refresh(roots: [book, other])
    let reads = index.reads
    index.refresh(roots: [book, other]); precondition(index.reads == reads)
    index.refresh(roots: [book, other], draft: (launch, "# Current draft\n\nUnsaved quasar observation."))
    precondition(index.search("quasar").first?.url == launch)
    precondition((try? String(contentsOf: launch, encoding: .utf8))?.contains("deployment") == true)
    try "# Changed\n\nOrchid greenhouse.".write(to: duplicate, atomically: true, encoding: .utf8)
    index.refresh(roots: [book, other])
    precondition(index.search("quasar").isEmpty)
    precondition(index.search("greenhouse").first?.url == duplicate)
    let renamed = other.appendingPathComponent("Renamed.md")
    try FileManager.default.moveItem(at: duplicate, to: renamed)
    index.refresh(roots: [book, other])
    precondition(index.documents[duplicate] == nil && index.search("greenhouse").first?.url == renamed)
    try FileManager.default.removeItem(at: renamed)
    index.refresh(roots: [book, other]); precondition(index.search("greenhouse").isEmpty)
    try Data([0xFF, 0xFE, 0x80]).write(to: other.appendingPathComponent("Unreadable.md"))
    index.refresh(roots: [book, other]); precondition(index.skipped == 1)
    index.refresh(roots: [other]); precondition(index.documents.isEmpty)
    // A larger collection exercises ranking and warm-index reuse without a model or service.
    for n in 0..<500 { _ = try write("Note \(n)", "# Working notes \(n)\n\nA small note about planning a project.\n\nReference folio\(n).") }
    let started = Date()
    index.refresh(roots: [book])
    let elapsed = Date().timeIntervalSince(started)
    precondition(index.search("folio427").first?.title == "Note 427")
    let warm = Date()
    for _ in 0..<20 { _ = index.search("project planning") }
    print(String(format: "PASS: exact passage anchors, repeated matches, local passage search, ranking, prefixes, typos, Unicode, recent notes, drafts, edits, rename/delete/close invalidation; 503 notes indexed in %.3fs, warm searches %.1fms each", elapsed, Date().timeIntervalSince(warm) * 1000 / 20))
}
