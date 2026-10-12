import Foundation

@MainActor func runLabelTests() throws {
    let fm = FileManager.default, base = fm.temporaryDirectory.appendingPathComponent("Omega-label-tests-" + UUID().uuidString)
    defer { try? fm.removeItem(at: base) }
    let root = base.appendingPathComponent("Notes"), other = base.appendingPathComponent("Other")
    try fm.createDirectory(at: root, withIntermediateDirectories: true); try fm.createDirectory(at: other, withIntermediateDirectories: true)
    var page = TaskDocument(title: "Release")
    page.goals = [TaskCheckItem(title: "Ship", details: TaskDetails(id: "goal-a"))]
    page.tasks = [TaskPageItem(title: "Parent", status: "In progress", subtasks: [TaskCheckItem(title: "Child", details: TaskDetails(id: "child", description: "Body 👋", due: "2026-12-04", labels: ["ads", "you"]), subtasks: [TaskCheckItem(title: "Deep child", details: TaskDetails(id: "deep", description: "Keep this", labels: ["ADS"]))])], details: TaskDetails(id: "parent", description: "**Description**", labels: ["Ads", "claude"], goals: ["goal-a"]))]
    let a = root.appendingPathComponent("Tasks.md"), b = other.appendingPathComponent("Archived.md"), normal = root.appendingPathComponent("Text.md")
    try page.markdown.write(to: a, atomically: true, encoding: .utf8)
    try page.markdown.write(to: b, atomically: true, encoding: .utf8)
    try "# ads\n\nPlain note is unchanged.".write(to: normal, atomically: true, encoding: .utf8)
    try fm.createSymbolicLink(at: root.appendingPathComponent("shortcut.md"), withDestinationURL: b)
    let store = Notebook(recovery: DraftRecovery(directory: base.appendingPathComponent("Recovery")))
    store.root = root; store.notebooks = [root, other]; store.library.archived.insert(b.path)
    let catalog = try TaskLabelCatalog.pages(in: [root, other, root])
    precondition(catalog.count == 2 && TaskLabelCatalog.labels(in: catalog).first(where: { $0.id == "ads" })?.uses == 6)
    try store.setLabelColor("Ads", .mint)
    var finished = false, failure: String?
    store.changeLabel("ADS", to: "Campaigns") { failure = $0; finished = true }
    precondition(finished && failure == nil, failure ?? "Rename did not finish")
    for file in [a, b] {
        let actual = try TaskDocument(markdown: String(contentsOf: file, encoding: .utf8))
        var expected = page; expected.replaceLabel("ads", with: "Campaigns")
        precondition(actual.markdown == expected.markdown, "Renaming lost task data")
    }
    let reopened = Notebook(recovery: store.recovery)
    precondition(reopened.labelPastel("CAMPAIGNS") == .mint && reopened.labelColors["ads"] == nil)
    store.changeLabel("Campaigns", to: "YOU") { failure = $0 }
    precondition(failure != nil, "Duplicate label accepted")
    store.changeLabel("Campaigns", to: "CAMPAIGNS") { failure = $0 }
    precondition(failure == nil && store.labelPastel("campaigns") == .mint)
    store.changeLabel("campaigns", to: nil) { failure = $0 }
    precondition(failure == nil)
    for file in [a, b] {
        let actual = try TaskDocument(markdown: String(contentsOf: file, encoding: .utf8))
        var expected = page; expected.replaceLabel("ads", with: nil)
        precondition(actual.markdown == expected.markdown, "Removing labels lost task data")
    }
    let unchanged = try String(contentsOf: normal, encoding: .utf8)
    precondition(unchanged == "# ads\n\nPlain note is unchanged.")
    let history = store.recovery.directory.appendingPathComponent("History/Label Changes")
    let copies = try fm.contentsOfDirectory(atPath: history.path)
    precondition(copies.count >= 2)
    let invalid = root.appendingPathComponent("Unsupported.md")
    try (TaskDocument.marker + "\n# Unsupported\n\n<!-- folio:task {bad} -->").write(to: invalid, atomically: true, encoding: .utf8)
    do { _ = try TaskLabelCatalog.pages(in: [root]); preconditionFailure("Unsupported task page was skipped") } catch {}
    print("PASS: shared label rename, case handling, archived/nested tasks, colors after restart, collision rejection, history and preserved task contents")
}
