import AppKit
import SwiftUI
import WebKit

@main struct ExternalEditCheck {
    @MainActor static func main() {
        setbuf(stdout, nil); _ = NSApplication.shared; NSApp.setActivationPolicy(.prohibited)
        Task { @MainActor in
            do { try await run(); print("PASS: native assistant and filesystem live updates"); exit(0) }
            catch { print("FAIL:", error); exit(1) }
        }
        NSApp.run()
    }
    @MainActor static func require(_ result: Bool, _ label: String) throws {
        if !result { throw GitFailure(label) }; print("PASS:", label)
    }
    @MainActor static func wait(_ label: String, seconds: Double = 5, _ predicate: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline { if predicate() { return }; try await Task.sleep(for: .milliseconds(20)) }
        throw GitFailure("Timed out: " + label)
    }
    @MainActor static func run() async throws {
        let temp = URL(fileURLWithPath: CommandLine.arguments[1]), root = temp.appendingPathComponent("Notebook")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let note = root.appendingPathComponent("Working together.md")
        let original = "# Working together\n\nFirst paragraph.\n\nKeep writing here.\n\nFinal thought.\n"
        try DraftRecovery.write(original, to: note)
        let notebook = Notebook(recovery: DraftRecovery(directory: temp.appendingPathComponent("Recovery")))
        notebook.root = root; notebook.notebooks = [root]; notebook.appearance = "dark"; notebook.zoom = 1
        notebook.entries = try NoteFiles.scan(root); notebook.trees[root] = notebook.entries; notebook.select(note)
        OpusIcons.register()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1040, height: 680), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        let host = NSHostingView(rootView: FolioView(notebook: notebook)); window.contentView = host
        try await wait("editor ready") { notebook.richEditor?.ready == true }
        try await Task.sleep(for: .milliseconds(400))
        let editor = notebook.richEditor!, web = editor.webView!
        func json(_ object: Any) -> String { String(decoding: try! JSONSerialization.data(withJSONObject: object), as: UTF8.self) }
        func js(_ code: String) async throws -> Any? { try await web.evaluateJavaScript(code) }
        func snapshot() async throws -> String { try await js("window.folio.snapshot().text") as! String }
        func call(_ name: String, _ arguments: [String: Any]) async -> [String: Any] {
            await withCheckedContinuation { continuation in
                AssistantService(notebook, history: temp.appendingPathComponent("Assistant history")).handle(["name": name, "arguments": arguments, "clientName": "claude-code"]) { continuation.resume(returning: $0) }
            }
        }
        _ = try await js("(()=>{const e=document.querySelector('#editor .tiptap');e.focus();const n=e.querySelectorAll('p')[1].firstChild,r=document.createRange();r.setStart(n,5);r.setEnd(n,12);const s=window.getSelection();s.removeAllRanges();s.addRange(r);return true})()")
        let updated = original.replacingOccurrences(of: "First", with: "Updated first").replacingOccurrences(of: "Final", with: "Updated final")
        let read = await call("read_note", ["path": note.path])
        let response = await call("update_note", ["path": note.path, "expected_revision": (read["structuredContent"] as! [String: Any])["revision"]!, "markdown": updated])
        try require(response["isError"] as? Bool == false, "Claude's MCP mutation succeeds through the real native bridge")
        try require(notebook.updateActivity?.message == "Updated by Claude", "toolbar identifies the actual MCP client")
        try require(try await js("window.getSelection().toString()") as! String == "writing", "selected text stays in place between two assistant edits")
        try require(try await snapshot() == updated && String(contentsOf: note, encoding: .utf8) == updated, "editor and durable Markdown agree immediately")
        try require(try await js("!!document.querySelector('.external-edit-highlight')") as! Bool, "changed text is highlighted without a fake cursor")
        host.layoutSubtreeIfNeeded(); try await Task.sleep(for: .milliseconds(150))
        if let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
            host.cacheDisplay(in: host.bounds, to: rep)
            if let data = rep.representation(using: .png, properties: [:]) { try data.write(to: temp.appendingPathComponent("assistant-update.png")) }
        }
        for index in 1...3 {
            let text = updated.replacingOccurrences(of: "Updated first", with: "File update \(index)")
            let start = Date(); try text.write(to: note, atomically: index != 3, encoding: .utf8)
            try await wait("file update", seconds: 1.5) { notebook.text == text }
            try require(Date().timeIntervalSince(start) < 1.5 && notebook.updateActivity?.message == "Updated externally", "file write \(index) appears promptly with an honest source label")
            try require(try await snapshot() == text, "WebKit receives file write \(index) without a page reload")
        }
        let beforePartial = notebook.text
        let writer = try FileHandle(forWritingTo: note)
        try writer.truncate(atOffset: 0)
        try writer.write(contentsOf: Data("# Half a".utf8))
        notebook.refreshFromDisk(reload: false)
        try await Task.sleep(for: .milliseconds(100))
        try require(try await snapshot() == beforePartial, "an in-progress filesystem write never flashes partial Markdown")
        try writer.truncate(atOffset: 0); try writer.seek(toOffset: 0)
        try writer.write(contentsOf: Data(beforePartial.utf8)); try writer.close()
        try await Task.sleep(for: .milliseconds(350))
        try require(try await snapshot() == beforePartial, "finishing a chunked write leaves the correct document intact")
        let beforeDialog = notebook.text
        _ = try await js("window.folio.command('appearance');true")
        let waitingText = beforeDialog.replacingOccurrences(of: "Updated final", with: "Received during a dialog")
        try waitingText.write(to: note, atomically: true, encoding: .utf8)
        try await wait("deferred update") { notebook.updateActivity?.message == "Update waiting for this edit" }
        try require(try await snapshot() == beforeDialog, "outside changes do not dismiss an active formatting dialog")
        _ = try await js("window.folio.command('closeWriting');true")
        try await wait("update after closing dialog") { notebook.text == waitingText }
        try require(try await snapshot() == waitingText, "deferred update arrives automatically when the dialog closes")
        let stale = try await js("window.folio.applyExternal(\(json(["id": "other-note", "base": waitingText, "text": "WRONG NOTE"])))") as! [String: Any]
        try require(stale["status"] as? String == "deferred", "a stale update cannot reach another selected note")
        let base = notebook.text
        _ = try await js("(()=>{const e=document.querySelector('#editor .tiptap');e.focus();const r=document.createRange();r.selectNodeContents(e.lastChild);r.collapse(false);const s=window.getSelection();s.removeAllRanges();s.addRange(r);document.execCommand('insertText',false,' My unsaved words');return true})()")
        try await wait("local typing") { notebook.dirty }
        let incoming = base.replacingOccurrences(of: "File update 3", with: "Claude's outside edit")
        try incoming.write(to: note, atomically: true, encoding: .utf8)
        try await wait("concurrent merge") { notebook.text.contains("Claude's outside edit") && notebook.text.contains("My unsaved words") && !notebook.dirty }
        let merged = try await snapshot()
        try require(merged == notebook.text && String(contentsOf: note, encoding: .utf8) == merged, "concurrent typing and independent outside changes both survive and save")
        // Competing replacements of the same words must not silently win.
        _ = try await js("window.folio.replaceForAssistant(\(json(["id": editor.identity, "expected": merged, "text": merged.replacingOccurrences(of: "writing here", with: "my decision")])));")
        try await wait("pending local replacement") { notebook.dirty }
        let conflicting = merged.replacingOccurrences(of: "writing here", with: "their decision")
        try conflicting.write(to: note, atomically: true, encoding: .utf8)
        try await wait("conflict notification") { notebook.updateActivity?.message == "Outside edits need review" }
        try require(notebook.text.contains("my decision") && String(contentsOf: note, encoding: .utf8) == conflicting, "overlapping edits keep both versions without an automatic modal")
        try require(notebook.recovery.hasCheckpoint(notebook.text, file: note), "unsaved side of a conflict has a crash recovery copy")
        // Finish the isolated fixture without asking the test user to resolve it.
        notebook.dirty = false; notebook.selected = nil
    }
}
