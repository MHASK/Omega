import AppKit
import SwiftUI
import WebKit

@main struct GitAppCheck {
    @MainActor static func main() {
        setbuf(stdout, nil)
        _ = NSApplication.shared; NSApp.setActivationPolicy(.prohibited)
        Task { @MainActor in
            do { try await run(); print("PASS native automatic-sync integration"); exit(0) }
            catch { print("FAIL:", error); exit(1) }
        }
        NSApp.run()
    }
    @MainActor static func require(_ value: Bool, _ message: String) throws { if !value { throw GitFailure(message) }; print("PASS:", message) }
    @MainActor static func wait(_ predicate: () -> Bool) async throws {
        for _ in 0..<200 { if predicate() { return }; try await Task.sleep(for: .milliseconds(100)) }
        throw GitFailure("Timed out waiting for the app")
    }
    @MainActor static func run() async throws {
        let temp = URL(fileURLWithPath: CommandLine.arguments[1]).resolvingSymlinksInPath(), fm = FileManager.default, runner = GitRunner(timeout: 10)
        let a = temp.appendingPathComponent("Notebook"), b = temp.appendingPathComponent("Peer"), remote = temp.appendingPathComponent("Remote.git")
        func git(_ args: [String], at root: URL) throws { _ = try runner.git(args, at: root) }
        try git(["init", "--bare", "--initial-branch=main", remote.path], at: temp); try git(["clone", remote.path, a.path], at: temp)
        func configure(_ root: URL) throws {
            try git(["config", "user.name", "Omega Test"], at: root); try git(["config", "user.email", "omega@example.invalid"], at: root)
            try git(["remote", "set-url", "origin", "https://example.invalid/team/notes.git"], at: root)
            try git(["config", "url.\(remote.path).insteadOf", "https://example.invalid/team/notes.git"], at: root)
        }
        try configure(a)
        let note = a.appendingPathComponent("Plan.md"), original = "# Quiet collaboration\n\nShared words.\n"
        try DraftRecovery.write(original, to: note); try DraftRecovery.write("Original\n", to: a.appendingPathComponent("Decision.md"))
        let notebook = Notebook(recovery: DraftRecovery(directory: temp.appendingPathComponent("Recovery")))
        notebook.root = a; notebook.notebooks = [a]; notebook.appearance = "dark"
        notebook.entries = try NoteFiles.scan(a); notebook.trees[a] = notebook.entries; notebook.select(note)
        OpusIcons.register()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 720), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        let host = NSHostingView(rootView: FolioView(notebook: notebook)); window.contentView = host
        try await wait { notebook.richEditor?.ready == true }
        try await Task.sleep(for: .milliseconds(500))
        let editor = notebook.richEditor!, web = editor.webView!
        func json(_ object: Any) throws -> String { String(decoding: try JSONSerialization.data(withJSONObject: object), as: UTF8.self) }
        func js(_ code: String) async throws -> Any? { try await web.evaluateJavaScript(code) }
        _ = try await js("window.folio.liveStart(\(json(["id": editor.identity])))")
        // Isolated live session: no credentials, public rooms or user notebooks involved.
        func checkpoint() async throws -> LiveCheckpoint {
            let result = try await js("(()=>{let s=window.folio.snapshot();return window.folio.gitApply({id:s.id,expected:s.text,text:s.text})})()") as! [String: Any]
            try await Task.sleep(for: .milliseconds(80))
            try notebook.prepareAssistantAccess()
            let cp = try JSONDecoder().decode(LiveCheckpoint.self, from: JSONSerialization.data(withJSONObject: result["checkpoint"]!))
            try LiveCheckpointStore.write(cp, to: LiveCheckpointStore.file(root: a, note: "Plan.md"), root: a)
            return cp
        }
        let initial = try await checkpoint()
        _ = try runner.sync(a, credentials: []); try git(["clone", remote.path, b.path], at: temp); try configure(b)
        let model = GitNotebooks(file: temp.appendingPathComponent("git-config.json")), entry = GitNotebook(path: a.path, provider: .github)
        try model.remember(entry)
        let remoteCheckpoint = try await model.merger.merge(mine: initial, resolvedText: "# Quiet collaboration\n\nShared words with a teammate.\n")!
        try DraftRecovery.write(remoteCheckpoint.text, to: b.appendingPathComponent("Plan.md"))
        try LiveCheckpointStore.write(remoteCheckpoint, to: LiveCheckpointStore.file(root: b, note: "Plan.md"), root: b)
        _ = try runner.sync(b, credentials: [])
        let session = try GitSyncSession(root: a)
        try await Task.detached { try session.fetch(credentials: []) }.value
        for pair in try session.sharedPairs() {
            let cp = try await model.merger.merge(mine: pair.mine, incoming: pair.incoming, mineText: pair.mineText, incomingText: pair.incomingText)!
            try session.writeCandidate(pair.path, data: Data(cp.text.utf8)); try session.writeCandidate(pair.checkpointPath, data: LiveCheckpointStore.encode(cp))
        }
        _ = try await js("(()=>{let e=document.querySelector('#editor .tiptap');e.focus();let r=document.createRange();r.selectNodeContents(e.lastChild);r.collapse(false);let s=window.getSelection();s.removeAllRanges();s.addRange(r);document.execCommand('insertText',false,' Still writing');return true})()")
        try await Task.sleep(for: .milliseconds(150))
        try await model.complete(session, entry: entry, notebook: notebook); session.discard()
        let disk = try String(contentsOf: note, encoding: .utf8)
        let saved = try LiveCheckpointStore.read(LiveCheckpointStore.file(root: a, note: "Plan.md"))!
        try require(disk.contains("teammate") && disk.contains("Still writing") && saved.text == disk && notebook.text == disk && !notebook.dirty, "native sync keeps the open editor, Markdown and durable checkpoint in agreement")
        let webText = try await js("window.folio.snapshot().text") as! String
        try require(webText == disk, "the editor stays mounted with all newer text after checkout")
        // Quiet automatic sync picks up incoming work without opening settings.
        _ = try runner.sync(b, credentials: [])
        try DraftRecovery.write("Arrived automatically\n", to: b.appendingPathComponent("Automatic.md")); _ = try runner.sync(b, credentials: [])
        model.nextSync[entry.path] = .distantPast; model.start(notebook: notebook); model.tick()
        try await wait { !model.busy && fm.fileExists(atPath: a.appendingPathComponent("Automatic.md").path) }
        model.timer?.invalidate(); model.timer = nil
        try require(model.messages[entry.path]?.hasPrefix("Up to date") == true, "automatic scheduler fetches and publishes without leaving the live document")
        // Trigger the same review UI and actions used by the shipping app.
        try DraftRecovery.write("My decision\n", to: a.appendingPathComponent("Decision.md"))
        try DraftRecovery.write("Incoming decision\n", to: b.appendingPathComponent("Decision.md")); _ = try runner.sync(b, credentials: [])
        model.sync(entry, notebook: notebook)
        try await wait { !model.busy }
        try require(model.reviews[entry.path]?.count == 1, "a background conflict becomes an in-app review")
        let review = model.reviews[entry.path]!.first!
        let reviewWindow = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1200, height: 800), styleMask: [.titled], backing: .buffered, defer: false)
        let reviewHost = NSHostingView(rootView: GitConflictView(notebook: notebook, git: model, entry: entry).environment(\.colorScheme, .dark))
        reviewWindow.contentView = reviewHost; reviewHost.layoutSubtreeIfNeeded(); try await Task.sleep(for: .milliseconds(1200))
        if let rep = reviewHost.bitmapImageRepForCachingDisplay(in: reviewHost.bounds) { reviewHost.cacheDisplay(in: reviewHost.bounds, to: rep); if let png = rep.representation(using: .png, properties: [:]) { try png.write(to: temp.appendingPathComponent("conflict-review.png")) } }
        func findWeb(_ view: NSView) -> WKWebView? {
            if let web = view as? WKWebView { return web }
            return view.subviews.compactMap { findWeb($0) }.first
        }
        guard let mergeWeb = findWeb(reviewHost) else { throw GitFailure("Missing merge editor") }
        for _ in 0..<100 {
            if (try? await mergeWeb.evaluateJavaScript("document.querySelector('#toolbar')?.hidden === false")) as? Bool == true { break }
            try await Task.sleep(for: .milliseconds(60))
        }
        _ = try await mergeWeb.evaluateJavaScript("document.querySelector('#useIncoming').click()")
        try await Task.sleep(for: .milliseconds(100))
        try require(model.sessions[entry.path]?.record.reviewDrafts?[review.path] != nil, "per-conflict choices persist through the native bridge into the Git review")
        if let output = ProcessInfo.processInfo.environment["OMEGA_GIT_CHECK_OUTPUT"], let rep = reviewHost.bitmapImageRepForCachingDisplay(in: reviewHost.bounds) {
            reviewHost.cacheDisplay(in: reviewHost.bounds, to: rep)
            if let png = rep.representation(using: .png, properties: [:]) { try png.write(to: URL(fileURLWithPath: output).appendingPathComponent("native-review-workspace.png")) }
        }
        _ = try await mergeWeb.evaluateJavaScript("let menu=document.querySelector('#fileMenu');menu.value='both';menu.dispatchEvent(new Event('change'))")
        try await wait { !model.busy }
        try require(model.reviews[entry.path] == nil && fm.fileExists(atPath: a.appendingPathComponent("Decision (incoming).md").path), "Keep both resolves the real Git conflict through the app")
        try require(try String(contentsOf: a.appendingPathComponent("Decision.md"), encoding: .utf8) == "My decision\n", "review preserves the chosen local version")
        model.automatic(entry, enabled: false)
        let reloaded = GitNotebooks(file: temp.appendingPathComponent("git-config.json"))
        try require(reloaded.notebooks.first?.autoSync == false, "automatic-sync preference persists per notebook")
        window.isReleasedWhenClosed = false; reviewWindow.isReleasedWhenClosed = false; window.close(); reviewWindow.close()
    }
}
