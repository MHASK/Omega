import XCTest
@testable import OmegaCore

final class PortableCheck: XCTestCase {
    func testFolderTasks() throws { try FolderTasksCheck.main() }
    func testGitSynchronization() throws { try GitSyncCheck.main() }
    func testGitDuringEdits() throws { try GitAutoSyncCheck.main() }
    func testLocalLinks() throws { try NoteLinkCheck.main() }
    func testTaskMetadataAndChecklist() throws {
        let text = "\u{FEFF}\n<!-- folio:tasks -->\n# Plan\n## To do\n* [ ] Work\n  <!-- folio:task {\"id\":\"a\",\"vendor\":{\"key\":\"keep\"},\"status\":\"Review\"} -->\n  + [x] Child\n"
        var doc = try TaskDocument(markdown: text)
        XCTAssertEqual(NoteChecklist.items(in: text).count, 2)
        _ = try doc.ensureLinkID("t:0.0")
        let child = doc.references.first { $0.kind == "subtask" }!
        try doc.moveTask(id: child.details.id!, parentID: nil)
        XCTAssertEqual(doc.tasks.count, 2)
        XCTAssertEqual(try TaskDocument(markdown: doc.markdown).tasks.first { $0.details.id == "a" }?.details.extra["vendor"], .object(["key": .string("keep")]))
    }
    func testDurableUndoAndRecovery() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("OmegaPortable-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("Note.md"), database = root.appendingPathComponent("undo.sqlite")
        let before = "# A note\n\nKeep café 🧑🏽‍💻 and | tables |.\n", after = before + "Local words.\n"
        try DraftRecovery.write(before, to: file)
        let recovery = DraftRecovery(directory: root.appendingPathComponent("recovery"))
        try recovery.checkpoint(after, original: before, file: file)
        XCTAssertTrue(recovery.hasCheckpoint(after, file: file))
        var history: UndoHistory? = UndoHistory(file: database)
        try history!.observe(before, at: file)
        try history!.record(before: before, after: after, at: file)
        history = nil; history = UndoHistory(file: database)
        XCTAssertEqual(try history!.travel(at: file, expected: after, redo: false, protect: { _ in })?.text, before)
        XCTAssertEqual(try history!.travel(at: file, expected: before, redo: true, protect: { _ in })?.text, after)
        XCTAssertThrowsError(try history!.travel(at: file, expected: "Another writer", redo: false, protect: { _ in }))
    }
}
