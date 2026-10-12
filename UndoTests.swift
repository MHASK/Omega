import Foundation

@MainActor func runUndoTests() {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("Folio-Undo-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    do {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let file = root.appendingPathComponent("note.md"), database = root.appendingPathComponent("history.sqlite")
        var history: UndoHistory? = UndoHistory(file: database)
        let original = "# Title\n\nCafé 日本語 👩🏽‍💻\n\n| A | B |\n| - | - |\n| 1 | 2 |\n"
        try history!.observe(original, at: file)
        var current = original
        // Far beyond ProseMirror's default 100-event history; no pruning.
        for i in 0..<1200 {
            let next = current + "\(i) 👋\n"
            try history!.record(before: current, after: next, at: file)
            current = next
        }
        let final = current
        history = nil
        history = UndoHistory(file: database)
        for _ in 0..<1200 { current = try history!.travel(at: file, expected: current, redo: false, protect: { _ in })!.text }
        precondition(current == original)
        let exhausted = try history!.travel(at: file, expected: current, redo: false, protect: { _ in })
        precondition(exhausted == nil)
        history = nil; history = UndoHistory(file: database)
        for _ in 0..<1200 { current = try history!.travel(at: file, expected: current, redo: true, protect: { _ in })!.text }
        precondition(current == final)
        print("PASS: 1,200 undo and redo steps across restarts, exact Unicode and Markdown")

        let grouped = root.appendingPathComponent("grouped.md")
        try history!.observe("", at: grouped)
        try history!.record(before: "", after: "a", at: grouped, beforeSelection: "before", afterSelection: "one", typing: true, now: 1)
        try history!.record(before: "a", after: "ab", at: grouped, beforeSelection: "one", afterSelection: "two", typing: true, now: 1.1)
        try history!.record(before: "ab", after: "abc", at: grouped, beforeSelection: "two", afterSelection: "after", typing: true, now: 1.2)
        let typed = try history!.travel(at: grouped, expected: "abc", redo: false, protect: { _ in })!
        precondition(typed.text == "" && typed.selection == "before")
        let retyped = try history!.travel(at: grouped, expected: "", redo: true, protect: { _ in })!
        precondition(retyped.text == "abc" && retyped.selection == "after")
        try history!.record(before: "abc", after: "", at: grouped)
        let undeleted = try history!.travel(at: grouped, expected: "", redo: false, protect: { _ in })!
        precondition(undeleted.text == "abc")
        print("PASS: natural typing groups, cursor restoration, whole-note deletion")

        do {
            _ = try history!.travel(at: grouped, expected: "abc", redo: false) { _ in throw CocoaError(.fileWriteNoPermission) }
            preconditionFailure("Failed recovery checkpoint must abort undo")
        } catch {}
        let afterFailure = try history!.travel(at: grouped, expected: "abc", redo: false, protect: { _ in })!
        precondition(afterFailure.text == "")
        try history!.record(before: "", after: "new branch", at: grouped)
        let invalidRedo = try history!.travel(at: grouped, expected: "new branch", redo: true, protect: { _ in })
        precondition(invalidRedo == nil)
        try history!.observe("outside change", at: grouped)
        let outsideUndo = try history!.travel(at: grouped, expected: "outside change", redo: false, protect: { _ in })!
        precondition(outsideUndo.text == "new branch")
        let renamed = root.appendingPathComponent("renamed.md")
        try history!.relocate(grouped, to: renamed)
        let renamedUndo = try history!.travel(at: renamed, expected: "new branch", redo: false, protect: { _ in })!
        precondition(renamedUndo.text == "")
        print("PASS: failed checkpoint rollback, new branches, external edits, rename history")

        // Exercise Notebook's actual saving, switching, and outside-reload path.
        let recovery = DraftRecovery(directory: root.appendingPathComponent("Recovery"))
        try DraftRecovery.write(original, to: file)
        let other = root.appendingPathComponent("other.md")
        try DraftRecovery.write("Other", to: other)
        let store = Notebook(recovery: recovery)
        store.root = root; store.select(file); store.edit("# Changed\n"); precondition(store.save())
        store.select(other); store.edit("Other edited"); precondition(store.save()); store.select(file)
        let switched = try store.stepHistory(redo: false)
        precondition(switched?.text == original)
        let disk = try String(contentsOf: file, encoding: .utf8); precondition(disk == original)
        let relaunched = Notebook(recovery: recovery); relaunched.root = root; relaunched.select(file)
        let reopened = try relaunched.stepHistory(redo: true); precondition(reopened?.text == "# Changed\n")
        print("PASS: actual note autosave, switch, reopen, and durable redo")

        let trash = DeletedNotes(directory: root.appendingPathComponent("Deleted"))
        let folder = root.appendingPathComponent("Folder"), child = folder.appendingPathComponent("nested.md")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try DraftRecovery.write(original, to: child)
        let entry = try trash.prepare(folder)
        try FileManager.default.removeItem(at: folder) // temporary fixture only
        // Simulate termination before the completed marker gets written.
        let restarted = DeletedNotes(directory: trash.directory)
        let recoveredEntry = try restarted.latest()!; precondition(recoveredEntry.backup == entry.backup)
        let restored = try restarted.restore(recoveredEntry)
        let restoredText = try String(contentsOf: restored.appendingPathComponent("nested.md"), encoding: .utf8)
        precondition(restoredText == original)
        let collision = try trash.prepare(folder); try trash.complete(collision)
        let alternate = try trash.restore(collision)
        precondition(alternate != folder && FileManager.default.fileExists(atPath: child.path))
        let noMore = try trash.latest(); precondition(noMore == nil)
        print("PASS: deleted folder recovery after restart, intact contents, collision-safe restoration")
        for phase in ["edit", "undo"] {
            let crash = root.appendingPathComponent(phase)
            try FileManager.default.createDirectory(at: crash, withIntermediateDirectories: true)
            let note = crash.appendingPathComponent("Crash.md")
            try DraftRecovery.write("Original 👋", to: note)
            let child = Process(); child.executableURL = URL(fileURLWithPath: CommandLine.arguments[0]); child.arguments = ["--undo-crash-fixture", crash.path, phase]
            try child.run(); child.waitUntilExit(); precondition(child.terminationStatus == 74)
            let recovery = DraftRecovery(directory: crash.appendingPathComponent("Recovery"))
            try recovery.recover()
            let expected = phase == "edit" ? "After 日本語" : "Original 👋"
            let disk = try String(contentsOf: note, encoding: .utf8); precondition(disk == expected)
            let reopened = UndoHistory(file: crash.appendingPathComponent("undo.sqlite"))
            try reopened.observe(disk, at: note)
            let step = try reopened.travel(at: note, expected: disk, redo: phase == "undo", protect: { _ in })
            precondition(step?.text == (phase == "edit" ? "Original 👋" : "After 日本語"))
        }
        print("PASS: abrupt process death before note save and during undo; recovered note and redo history survive")
        print("All persistent undo checks passed.")
    } catch { fputs("Undo test failed: \(error)\n", stderr); exit(1) }
}
