import AppKit
import SwiftUI

@main
struct FolioMain {
    @MainActor static func main() {
        // Tests must never write the running app's preferences. A bare helper
        // executable has its own defaults domain, including crash-test children.
        if ["--self-test", "--mcp-test", "--undo-test"].contains(where: CommandLine.arguments.contains), Bundle.main.bundleIdentifier != nil {
            let helper = FileManager.default.temporaryDirectory.appendingPathComponent("Folio-Tests-" + UUID().uuidString)
            do {
                try FileManager.default.copyItem(at: URL(fileURLWithPath: CommandLine.arguments[0]), to: helper)
                let signer = Process(); signer.executableURL = URL(fileURLWithPath: "/usr/bin/codesign"); signer.arguments = ["--force", "--sign", "-", helper.path]
                signer.standardOutput = FileHandle.nullDevice; signer.standardError = FileHandle.nullDevice
                try signer.run(); signer.waitUntilExit(); guard signer.terminationStatus == 0 else { throw CocoaError(.executableNotLoadable) }
                let child = Process(); child.executableURL = helper; child.arguments = Array(CommandLine.arguments.dropFirst())
                try child.run(); child.waitUntilExit(); try? FileManager.default.removeItem(at: helper)
                exit(child.terminationStatus)
            } catch { fputs("Couldn’t start isolated tests: \(error)\n", stderr); exit(1) }
        }
        if let i = CommandLine.arguments.firstIndex(of: "--finish-update"), CommandLine.arguments.count > i + 1 { exit(FolioUpdates.finish(planURL: URL(fileURLWithPath: CommandLine.arguments[i + 1]))) }
        if CommandLine.arguments.contains("--mcp") { FolioMCP.run(); return }
        if CommandLine.arguments.contains("--mcp-test") { runAssistantTests(); return }
        if CommandLine.arguments.contains("--undo-test") { runUndoTests(); return }
        if let i = CommandLine.arguments.firstIndex(of: "--undo-crash-fixture"), CommandLine.arguments.count > i + 2 {
            let directory = URL(fileURLWithPath: CommandLine.arguments[i + 1]), undo = CommandLine.arguments[i + 2] == "undo"
            do {
                let file = directory.appendingPathComponent("Crash.md"), recovery = DraftRecovery(directory: directory.appendingPathComponent("Recovery"))
                let history = UndoHistory(file: directory.appendingPathComponent("undo.sqlite"))
                try history.observe("Original 👋", at: file)
                try history.record(before: "Original 👋", after: "After 日本語", at: file)
                try recovery.checkpoint("After 日本語", original: "Original 👋", file: file)
                if undo {
                    try DraftRecovery.write("After 日本語", to: file); recovery.clear(file)
                    _ = try history.travel(at: file, expected: "After 日本語", redo: false) { try recovery.checkpoint($0, original: "After 日本語", file: file) }
                }
                _exit(74) // No deinitializers, history close, autosave, or quit handler.
            } catch { fputs("Crash fixture failed: \(error)\n", stderr); exit(1) }
        }
        if let i = CommandLine.arguments.firstIndex(of: "--recovery-fixture"), CommandLine.arguments.count > i + 1 {
            let directory = URL(fileURLWithPath: CommandLine.arguments[i + 1])
            let store = Notebook(recovery: DraftRecovery(directory: directory.appendingPathComponent("Recovery")))
            store.root = directory; store.select(directory.appendingPathComponent("Crash.md"))
            store.edit("# Survived\n\nUnflushed edits, Café 日本語 👋")
            // Simulate abrupt termination: no run loop, timer, save, or quit callback.
            _exit(73)
        }
        if CommandLine.arguments.contains("--self-test") { runSelfTests(); return }
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        // A requested move runs only on its designated update, before any
        // editor, file watcher, Git session or assistant can open old paths.
        let migration = NotebookMigration()
        do {
            if let request = try migration.due(build: Int(Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "0") ?? 0) {
                // The headless updater helper may still be waiting for this
                // launch; only another interactive app can have editors open.
                guard NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? "local.folio.notes").allSatisfy({ $0.processIdentifier == getpid() || $0.activationPolicy == .prohibited }) else {
                    let alert = NSAlert(); alert.messageText = "Close the other Omega window first"
                    alert.informativeText = "Omega needs to finish your requested notebook move before opening this version."; alert.runModal(); return
                }
                do { try migration.run(build: request.minimumBuild) }
                catch {
                    let alert = NSAlert(); alert.messageText = "The notebook move needs attention"
                    alert.informativeText = error.localizedDescription; alert.runModal()
                    // Once renamed, finish path migration before creating any
                    // stores. Retry on next launch; never seed a second notebook.
                    if !FileManager.default.fileExists(atPath: request.source) { return }
                }
            }
        } catch {
            let alert = NSAlert(); alert.messageText = "Couldn’t read the pending notebook move"
            alert.informativeText = error.localizedDescription; alert.runModal(); return
        }
        let delegate = AppDelegate()
        app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, NSMenuItemValidation {
    let notebook = Notebook()
    var window: NSWindow!
    private var closing = false
    private var updating = false
    var assistantServer: AssistantServer?
    func applicationDidFinishLaunching(_ notification: Notification) {
        OpusIcons.register()
        installMenus()
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 620), styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        window.title = "Omega"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.titlebarSeparatorStyle = .none
        window.isMovableByWindowBackground = false
        window.acceptsMouseMovedEvents = true
        window.backgroundColor = Ink.paper
        window.minSize = NSSize(width: 360, height: 320)
        let content = NSHostingView(rootView: FolioView(notebook: notebook))
        content.sizingOptions = []
        content.safeAreaRegions = []
        content.autoresizingMask = [.width, .height]
        window.contentView = content
        window.delegate = self
        window.isReleasedWhenClosed = false
        window.setFrameAutosaveName("FolioWindow")
        window.center()
        positionWindowButtons()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        DispatchQueue.main.async { self.notebook.start(); GitNotebooks.shared.start(notebook: self.notebook); self.startAssistantServer(); GitHubUpdater.shared.start(notebook: self.notebook) { self.updating = true } }
    }
    func positionWindowButtons() {
        guard let window else { return }
        guard !window.styleMask.contains(.fullScreen) else { return }
        for (index, type) in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton].enumerated() {
            guard let button = window.standardWindowButton(type), let parent = button.superview else { continue }
            button.setFrameOrigin(NSPoint(x: 13 + CGFloat(index) * 20, y: parent.bounds.height - 19 - button.frame.height / 2))
        }
    }
    func windowDidResize(_ notification: Notification) { positionWindowButtons() }
    func windowWillEnterFullScreen(_ notification: Notification) { notebook.fullscreen = true }
    func windowDidEnterFullScreen(_ notification: Notification) { notebook.fullscreen = true }
    func windowWillExitFullScreen(_ notification: Notification) { notebook.fullscreen = false }
    func windowDidExitFullScreen(_ notification: Notification) { notebook.fullscreen = false; positionWindowButtons() }
    func windowDidFailToEnterFullScreen(_ window: NSWindow) { notebook.fullscreen = false }
    func windowDidFailToExitFullScreen(_ window: NSWindow) { notebook.fullscreen = true }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if notebook.gitSyncing { return .terminateCancel }
        if updating { return .terminateNow }
        notebook.synchronizeEditors { success in sender.reply(toApplicationShouldTerminate: success && self.notebook.save()) }
        return .terminateLater
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if closing { closing = false; return true }
        notebook.afterSync {
            if self.notebook.save() { self.closing = true; sender.performClose(nil) }
        }
        return false
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool { window.makeKeyAndOrderFront(nil); return true }
    func application(_ sender: NSApplication, openFiles filenames: [String]) {
        if let file = filenames.first { notebook.open(URL(fileURLWithPath: file)) }
        sender.reply(toOpenOrPrint: .success)
    }
    func installMenus() {
        let main = NSMenu()
        let application = NSMenu()
        add(application, "About Omega", #selector(about), "")
        add(application, "Check for Updates…", #selector(checkUpdates), "")
        add(application, "Install Update from File…", #selector(installUpdate), "")
        add(application, "Settings…", #selector(showSettings), ",")
        add(application, "Connect Assistants…", #selector(connectAssistants), "")
        application.addItem(.separator())
        add(application, "Hide Omega", #selector(NSApplication.hide(_:)), "h", target: NSApp)
        add(application, "Quit Omega", #selector(NSApplication.terminate(_:)), "q", target: NSApp)
        top(main, "Omega", application)
        let file = NSMenu(title: "File")
        add(file, "New Note", #selector(newNote), "n")
        add(file, "New Task Page", #selector(newTaskPage), "")
        add(file, "New Folder…", #selector(newFolder), "n", modifiers: [.command, .shift])
        add(file, "New Notebook…", #selector(newNotebook), "n", modifiers: [.command, .option])
        add(file, "Open File…", #selector(openFile), "o")
        add(file, "Open Folder…", #selector(openFolder), "o", modifiers: [.command, .shift])
        file.addItem(.separator())
        add(file, "Save", #selector(save), "s")
        add(file, "Save a Copy…", #selector(saveCopy), "s", modifiers: [.command, .shift])
        add(file, "Rename…", #selector(rename), "")
        add(file, "Show in Finder", #selector(reveal), "")
        file.addItem(.separator())
        add(file, "Close Window", #selector(NSWindow.performClose(_:)), "w", target: nil)
        top(main, "File", file)
        let edit = NSMenu(title: "Edit")
        add(edit, "Undo", #selector(undoEdit), "z")
        add(edit, "Redo", #selector(redoEdit), "z", modifiers: [.command, .shift])
        add(edit, "Restore Last Deleted Note or Folder", #selector(restoreDeleted), "")
        edit.addItem(.separator())
        add(edit, "Cut", #selector(NSText.cut(_:)), "x", target: nil)
        add(edit, "Copy", #selector(NSText.copy(_:)), "c", target: nil)
        add(edit, "Paste", #selector(NSText.paste(_:)), "v", target: nil)
        add(edit, "Select All", #selector(NSText.selectAll(_:)), "a", target: nil)
        edit.addItem(.separator())
        add(edit, "Find in Note…", #selector(findInNote), "f")
        add(edit, "Find a Note…", #selector(search), "k")
        top(main, "Edit", edit)
        let format = NSMenu(title: "Format")
        add(format, "Bold", #selector(bold), "b")
        add(format, "Italic", #selector(italic), "i")
        add(format, "Underline", #selector(underline), "u")
        add(format, "Add Comment…", #selector(addComment), "m", modifiers: [.command, .option])
        add(format, "Heading", #selector(heading), "2", modifiers: [.command, .option])
        add(format, "Checklist", #selector(checklist), "l", modifiers: [.command, .shift])
        top(main, "Format", format)
        let view = NSMenu(title: "View")
        add(view, "Back", #selector(navigateBack), "[")
        add(view, "Forward", #selector(navigateForward), "]")
        view.addItem(.separator())
        add(view, "Zoom In", #selector(zoomIn), "=")
        add(view, "Zoom In", #selector(zoomIn), "+")
        view.items.last?.isHidden = true
        view.items.last?.allowsKeyEquivalentWhenHidden = true
        add(view, "Zoom Out", #selector(zoomOut), "-")
        add(view, "Default Size", #selector(zoomReset), "0")
        view.addItem(.separator())
        add(view, "Larger Document Text", #selector(writingLarger), "=", modifiers: [.command, .option])
        add(view, "Larger Document Text", #selector(writingLarger), "+", modifiers: [.command, .option])
        view.items.last?.isHidden = true
        view.items.last?.allowsKeyEquivalentWhenHidden = true
        add(view, "Smaller Document Text", #selector(writingSmaller), "-", modifiers: [.command, .option])
        add(view, "Default Document Text", #selector(writingReset), "0", modifiers: [.command, .option])
        view.addItem(.separator())
        add(view, "Toggle Markdown Source", #selector(sourceMode), "m", modifiers: [.command, .shift])
        add(view, "Toggle Sidebar", #selector(sidebar), "\\")
        add(view, "Toggle Reading View", #selector(reading), "p", modifiers: [.command, .shift])
        add(view, "Toggle Dark Mode", #selector(dark), "d", modifiers: [.command, .shift])
        view.addItem(.separator())
        add(view, "Enter Full Screen", #selector(NSWindow.toggleFullScreen(_:)), "f", modifiers: [.command, .control], target: nil)
        top(main, "View", view)
        let windowMenu = NSMenu(title: "Window")
        add(windowMenu, "Minimize", #selector(NSWindow.performMiniaturize(_:)), "m", target: nil)
        top(main, "Window", windowMenu)
        NSApp.windowsMenu = windowMenu
        NSApp.mainMenu = main
    }
    func top(_ main: NSMenu, _ title: String, _ submenu: NSMenu) {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: ""); item.submenu = submenu; main.addItem(item)
    }
    func add(_ menu: NSMenu, _ title: String, _ action: Selector, _ key: String, modifiers: NSEvent.ModifierFlags = .command, target: AnyObject? = nil) {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        let native = ["undo:", "redo:", "cut:", "copy:", "paste:", "selectAll:", "performClose:", "performMiniaturize:", "toggleFullScreen:"]
        item.target = native.contains(NSStringFromSelector(action)) ? target : (target ?? self)
        item.keyEquivalentModifierMask = modifiers; menu.addItem(item)
    }
    @objc func newNote() { notebook.newNote() }
    @objc func newTaskPage() { notebook.newTaskPage() }
    @objc func newNotebook() { notebook.newNotebook() }
    @objc func newFolder() { notebook.newFolder() }
    @objc func underline() { notebook.richEditor?.command("underline") }
    @objc func addComment() { notebook.richEditor?.command("comment") }
    @objc func writingLarger() { notebook.changeWritingSize(1) }
    @objc func writingSmaller() { notebook.changeWritingSize(-1) }
    @objc func writingReset() { notebook.changeWritingSize(0) }
    @objc func zoomIn() { notebook.changeZoom(1) }
    @objc func zoomOut() { notebook.changeZoom(-1) }
    @objc func zoomReset() { notebook.changeZoom(0) }
    @objc func sourceMode() { notebook.richEditor?.command("source") }
    @objc func undoEdit() { if notebook.checklistFolder != nil { notebook.folderTasksEditor?.command("undo"); return }; if notebook.showingSettings { NSApp.sendAction(Selector(("undo:")), to: nil, from: self); return }; if NSApp.keyWindow?.firstResponder is NSTextView { NSApp.sendAction(Selector(("undo:")), to: nil, from: self) } else if !notebook.undoRecentDeletion() { notebook.richEditor?.command("undo") } }
    @objc func redoEdit() { if notebook.checklistFolder != nil { notebook.folderTasksEditor?.command("redo"); return }; if notebook.showingSettings { NSApp.sendAction(Selector(("redo:")), to: nil, from: self); return }; if NSApp.keyWindow?.firstResponder is NSTextView { NSApp.sendAction(Selector(("redo:")), to: nil, from: self) } else { notebook.richEditor?.command("redo") } }
    @objc func restoreDeleted() { notebook.restoreLastDeleted() }
    @objc func openFile() { notebook.chooseFile() }
    @objc func openFolder() { notebook.chooseFolder() }
    @objc func save() { notebook.afterSync { self.notebook.save() } }
    @objc func saveCopy() { notebook.afterSync { self.notebook.saveCopy() } }
    @objc func rename() { if let url = notebook.selected { notebook.rename(url) } }
    @objc func reveal() { notebook.reveal() }
    @objc func navigateBack() { notebook.travelNavigation(forward: false) }
    @objc func navigateForward() { notebook.travelNavigation(forward: true) }
    @objc func sidebar() { notebook.toggleSidebar() }
    @objc func reading() { notebook.reading.toggle() }
    @objc func dark() { notebook.setAppearance(notebook.appearance == "dark" ? "light" : "dark") }
    @objc func bold() { notebook.format("**", suffix: "**") }
    @objc func italic() { notebook.format("*", suffix: "*") }
    @objc func heading() { notebook.format("## ") }
    @objc func checklist() { notebook.format("- [ ] ") }
    @objc func search() { NotificationCenter.default.post(name: .init("FolioSearch"), object: nil) }
    @objc func findInNote() { if notebook.checklistFolder != nil { notebook.folderTasksEditor?.command("find") } else { notebook.richEditor?.command("find") } }
    func startAssistantServer() {
        guard UserDefaults.standard.bool(forKey: "assistantAccess") else { return }
        do { assistantServer = try AssistantServer(notebook: notebook) }
        catch { notebook.status = "Assistant connection unavailable: " + error.localizedDescription }
    }
    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        if item.action == #selector(navigateBack) { return notebook.canGoBack && !notebook.navigating && !notebook.showingSettings }
        if item.action == #selector(navigateForward) { return notebook.canGoForward && !notebook.navigating && !notebook.showingSettings }
        if notebook.checklistFolder != nil {
            let editorActions: [Selector] = [#selector(rename), #selector(sourceMode), #selector(reading), #selector(bold), #selector(italic), #selector(heading), #selector(checklist), #selector(underline), #selector(addComment), #selector(writingLarger), #selector(writingSmaller), #selector(writingReset)]
            if editorActions.contains(where: { $0 == item.action }) { return false }
        }
        guard notebook.showingSettings else { return true }
        let noteActions: [Selector] = [#selector(newNote), #selector(newTaskPage), #selector(newNotebook), #selector(newFolder), #selector(openFile), #selector(openFolder), #selector(rename), #selector(sourceMode), #selector(findInNote), #selector(sidebar), #selector(reading), #selector(bold), #selector(italic), #selector(heading), #selector(checklist), #selector(restoreDeleted)]
        return !noteActions.contains(where: { $0 == item.action })
    }
    @objc func showSettings() {
        notebook.afterSync {
            guard self.notebook.save() else { return }
            self.notebook.searching = false
            self.window.makeFirstResponder(nil)
            self.notebook.showingSettings = true
            self.window.makeKeyAndOrderFront(nil)
        }
    }
    func setAssistantAccess(_ enabled: Bool) {
        if enabled {
            UserDefaults.standard.set(true, forKey: "assistantAccess"); startAssistantServer()
            if assistantServer == nil { UserDefaults.standard.set(false, forKey: "assistantAccess") }
        } else {
            assistantServer?.stop(); assistantServer = nil
            UserDefaults.standard.set(false, forKey: "assistantAccess")
        }
    }
    @objc func connectAssistants() {
        let enabled = assistantServer != nil
        let panel = NSAlert()
        panel.messageText = "Connect your assistants"
        panel.informativeText = "Let a local MCP client read, search, create, and organize the notebooks open in Omega, including tasks, subtasks, goals, and task statuses. All edits stay on this Mac. Conflicting updates are rejected, and replaced notes have a saved history copy.\n\nAccess is currently " + (enabled ? "on." : "off.") + "\nUse Copy Configuration in your MCP client's settings."
        panel.addButton(withTitle: enabled ? "Copy Configuration" : "Enable & Copy Configuration")
        if enabled { panel.addButton(withTitle: "Turn Off Access") }
        panel.addButton(withTitle: "Done")
        switch panel.runModal() {
        case .alertFirstButtonReturn:
            if !enabled { UserDefaults.standard.set(true, forKey: "assistantAccess"); startAssistantServer() }
            guard assistantServer != nil else { return }
            let config: [String: Any] = ["mcpServers": ["folio": ["command": Bundle.main.executableURL!.path, "args": ["--mcp"]]]]
            let data = try! JSONSerialization.data(withJSONObject: config, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
            NSPasteboard.general.clearContents(); NSPasteboard.general.setString(String(decoding: data, as: UTF8.self), forType: .string)
        case .alertSecondButtonReturn where enabled:
            UserDefaults.standard.set(false, forKey: "assistantAccess"); assistantServer?.stop(); assistantServer = nil
        default: break
        }
    }
    @objc func checkUpdates() { notebook.settingsDestination = "About Omega"; notebook.showingSettings = true; NotificationCenter.default.post(name: .init("OmegaShowUpdateSettings"), object: nil); GitHubUpdater.shared.check() }
    @objc func installUpdate() { FolioUpdates.choose(notebook: notebook) { self.updating = true } }
    @objc func about() {
        NSApp.orderFrontStandardAboutPanel(options: [.applicationName: "Omega", .applicationVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "", .version: Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "", .credits: NSAttributedString(string: "A quiet place for your words.\nNative, local, and simply yours.")])
    }
}

@MainActor
func runSelfTests() {
    let preferenceKeys = ["lastNote", "lastFolder", "notebooks", "documentZoom", "sidebarWidth", "notebookColors", "recentNotes"]
    let preferences = preferenceKeys.map { ($0, UserDefaults.standard.object(forKey: $0)) }
    defer { for (key, value) in preferences { UserDefaults.standard.set(value, forKey: key) } }
    do {
        try runSearchTests()
        try runLabelTests()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Folio-tests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = root.appendingPathComponent("Nested")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let original = "# Hello 👋\n\nCafé **bold** and 日本語.\n- [ ] A task\n"
        let note = root.appendingPathComponent("Test.md")
        try original.write(to: note, atomically: true, encoding: .utf8)
        try "Nested".write(to: folder.appendingPathComponent("Nested.markdown"), atomically: true, encoding: .utf8)
        try "Ignore".write(to: root.appendingPathComponent("Other.json"), atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(at: folder.appendingPathComponent("Loop"), withDestinationURL: root)
        let entries = try NoteFiles.scan(root)
        precondition(NoteFiles.flatten(entries).filter { !$0.isFolder }.count == 2)
        precondition(NoteFiles.uniqueURL(in: root, name: "Test").lastPathComponent == "Test 2.md")
        precondition(!NoteFiles.validName("../bad") && NoteFiles.validName("My note"))
        let store = Notebook(recovery: DraftRecovery(directory: root.appendingPathComponent("Recovery")))
        store.root = root; store.entries = entries; store.select(note)
        precondition(store.text == original)
        store.edit(original + "\nSaved locally.")
        precondition(store.save())
        let saved = try String(contentsOf: note, encoding: .utf8)
        precondition(saved == original + "\nSaved locally.")
        let pending = saved + "\nKeep my unsaved words."
        store.edit(pending)
        try "# Half a write".write(to: note, atomically: false, encoding: .utf8)
        store.refreshFromDisk()
        precondition(store.text == pending && store.dirty)
        try saved.write(to: note, atomically: false, encoding: .utf8)
        store.refreshFromDisk()
        precondition(!store.dirty && (try? String(contentsOf: note, encoding: .utf8)) == pending)
        let external = "# Changed externally\n"
        try external.write(to: note, atomically: true, encoding: .utf8)
        store.refreshFromDisk()
        precondition(store.text == pending) // A direct write is observed before it is displayed.
        let reloadDeadline = Date().addingTimeInterval(1)
        while store.text != external && Date() < reloadDeadline { RunLoop.current.run(until: Date().addingTimeInterval(0.02)) }
        precondition(store.text == external)
        store.newNote()
        precondition(store.selected?.lastPathComponent == "Untitled.md")
        store.edit("# New\n\nA new note.")
        store.select(note)
        let switched = try String(contentsOf: root.appendingPathComponent("Untitled.md"), encoding: .utf8)
        precondition(switched == "# New\n\nA new note.")
        store.edit(external + "Saved before move.")
        store.moveItem(note, into: folder)
        let moved = folder.appendingPathComponent("Test.md")
        precondition(store.selected == moved)
        precondition((try? String(contentsOf: moved, encoding: .utf8)) == external + "Saved before move.")
        try "A different note".write(to: note, atomically: true, encoding: .utf8)
        store.moveItem(note, into: folder)
        precondition((try? String(contentsOf: folder.appendingPathComponent("Test 2.md"), encoding: .utf8)) == "A different note")
        precondition((try? String(contentsOf: moved, encoding: .utf8)) == external + "Saved before move.")
        let archive = root.appendingPathComponent("Archive")
        try FileManager.default.createDirectory(at: archive, withIntermediateDirectories: false)
        store.moveItem(folder, into: archive)
        precondition(store.selected == archive.appendingPathComponent("Nested/Test.md"))
        store.moveItem(archive, into: archive.appendingPathComponent("Nested"))
        precondition(FileManager.default.fileExists(atPath: archive.appendingPathComponent("Nested/Test.md").path))
        let rebased = NoteFiles.rebaseLinks("![Photo](assets/a%20b.png)\n\n`[example](assets/code.png)`\n\n[site](https://example.com)", from: root.appendingPathComponent("Photo.md"), to: folder.appendingPathComponent("Photo.md"), moving: root.appendingPathComponent("Photo.md"), to: folder.appendingPathComponent("Photo.md"))
        precondition(rebased.contains("![Photo](../assets/a%20b.png)"))
        precondition(rebased.contains("`[example](assets/code.png)`") && rebased.contains("https://example.com"))
        // Multiple independent top-level notebooks and cross-notebook moves.
        let firstBook = root.appendingPathComponent("First book")
        try FileManager.default.createDirectory(at: firstBook, withIntermediateDirectories: false)
        let books = Notebook(recovery: DraftRecovery(directory: root.appendingPathComponent("Book recovery")))
        books.root = firstBook; books.notebooks = [firstBook]
        let secondBook = try books.createNotebook(named: "Second book", beside: firstBook)
        precondition(secondBook.deletingLastPathComponent() == firstBook.deletingLastPathComponent())
        precondition(books.notebooks == [firstBook, secondBook])
        precondition(UserDefaults.standard.stringArray(forKey: "notebooks") == [firstBook.path, secondBook.path])
        do { _ = try books.createNotebook(named: "Second book", beside: firstBook); preconditionFailure("Duplicate notebook overwrote data") }
        catch { precondition(FileManager.default.fileExists(atPath: secondBook.path)) }
        books.creationFolder = secondBook; books.newNote()
        let secondNote = secondBook.appendingPathComponent("Untitled.md")
        precondition(books.selected == secondNote && books.root == secondBook)
        books.edit("Keep me across notebooks"); books.moveItem(secondNote, into: firstBook)
        precondition(books.selected == firstBook.appendingPathComponent("Untitled.md") && books.root == firstBook)
        precondition(!FileManager.default.fileExists(atPath: secondNote.path))
        precondition((try? String(contentsOf: books.selected!, encoding: .utf8)) == "Keep me across notebooks")
        books.resizeSidebar(325); precondition(books.sidebarWidth == 325)
        books.resizeSidebar(20); precondition(books.sidebarWidth == 160)
        books.changeZoom(0); books.changeZoom(1); precondition(books.zoom == 1.5)
        books.changeZoom(-1); precondition(books.zoom == 1.4)
        books.visibleSidebarWidth = 325; books.sidebarHeight = 700
        books.dropFrames = [secondBook: CGRect(x: 0, y: 300, width: 325, height: 35)]
        books.updateDrag(books.selected!, at: CGPoint(x: 300, y: 310)); precondition(books.dragDestination == secondBook)
        books.finishDrag(); precondition(books.root == secondBook)
        precondition(UserDefaults.standard.string(forKey: "lastFolder") == secondBook.path)

        // Context menus operate on the clicked item and preserve an open descendant.
        let actions = Notebook(recovery: DraftRecovery(directory: root.appendingPathComponent("Action recovery")))
        let actionBook = root.appendingPathComponent("Menu book")
        let dotted = actionBook.appendingPathComponent("Drafts.v1")
        let nested = dotted.appendingPathComponent("Nested")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        let actionNote = nested.appendingPathComponent("My note.markdown")
        try "Original".write(to: actionNote, atomically: true, encoding: .utf8)
        actions.root = actionBook; actions.notebooks = [actionBook]; actions.reloadTree(); actions.select(actionNote)
        actions.edit("Pending edit survives folder rename 👋")
        let renamedFolder = try actions.renameItem(dotted, to: "Drafts.v2")
        precondition(renamedFolder.lastPathComponent == "Drafts.v2")
        precondition(actions.selected?.path == renamedFolder.appendingPathComponent("Nested/My note.markdown").path)
        precondition(actions.creationFolder?.path == renamedFolder.appendingPathComponent("Nested").path)
        precondition(actions.expanded.contains(renamedFolder.path))
        precondition((try? String(contentsOf: actions.selected!, encoding: .utf8)) == "Pending edit survives folder rename 👋")
        actions.edit("Saved after rename")
        precondition(actions.save())
        precondition(!FileManager.default.fileExists(atPath: actionNote.path))
        let renamedNote = try actions.renameItem(actions.selected!, to: "Café.markdown")
        precondition(renamedNote.lastPathComponent == "Café.markdown")
        let caseNote = try actions.renameItem(renamedNote, to: "CAFÉ")
        precondition(caseNote.lastPathComponent == "CAFÉ.markdown")
        let collision = nested.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Drafts.v2/Nested/Existing.markdown")
        try "Do not replace".write(to: collision, atomically: true, encoding: .utf8)
        do { _ = try actions.renameItem(caseNote, to: "Existing"); preconditionFailure("Rename overwrote a sibling") } catch {}
        precondition((try? String(contentsOf: collision, encoding: .utf8)) == "Do not replace")
        precondition(actions.selected == caseNote)
        for invalid in ["../Bad", ".hidden", "Bad\nName", "", "Bad\0Name"] {
            do { _ = try actions.renameItem(caseNote, to: invalid); preconditionFailure("Invalid name accepted") } catch {}
        }
        actions.edit("Pending duplicate")
        let duplicate = try actions.duplicateItem(caseNote)
        precondition((try? String(contentsOf: caseNote, encoding: .utf8)) == "Pending duplicate")
        precondition((try? String(contentsOf: duplicate, encoding: .utf8)) == "Pending duplicate")
        precondition(actions.selected == duplicate)
        let secondCopy = try actions.duplicateItem(caseNote)
        precondition(secondCopy != duplicate && secondCopy.lastPathComponent == "CAFÉ copy 2.markdown")
        let folderCopy = try actions.duplicateItem(renamedFolder)
        precondition(FileManager.default.fileExists(atPath: folderCopy.appendingPathComponent("Nested/CAFÉ.markdown").path))
        // Empty space promotes folders; an explicit notebook row still moves inside it.
        actions.visibleSidebarWidth = 300; actions.sidebarHeight = 700
        actions.dropFrames = [actionBook: CGRect(x: 0, y: 40, width: 300, height: 35), duplicate: CGRect(x: 25, y: 100, width: 270, height: 30)]
        actions.updateDrag(renamedFolder, at: CGPoint(x: 100, y: 650))
        precondition(actions.dragPromotesNotebook && actions.dragDestination == nil)
        actions.updateDrag(renamedFolder, at: CGPoint(x: 100, y: 50))
        precondition(!actions.dragPromotesNotebook && actions.dragDestination == actionBook)
        actions.updateDrag(renamedFolder, at: CGPoint(x: 400, y: 650))
        precondition(!actions.dragPromotesNotebook && actions.dragDestination == nil)
        actions.updateDrag(renamedFolder, at: CGPoint(x: 100, y: 650)); actions.finishDrag()
        let promoted = root.appendingPathComponent("Drafts.v2")
        precondition(actions.notebooks.map(\.path) == [actionBook.path, promoted.path])
        precondition(!FileManager.default.fileExists(atPath: renamedFolder.path))
        precondition(actions.root?.path == promoted.path && actions.selected?.path == promoted.appendingPathComponent("Nested/CAFÉ copy 2.markdown").path)
        actions.setTint(.lavender, for: promoted)
        let newBook = try actions.renameItem(promoted, to: "Promoted notebook")
        precondition(actions.tint(for: newBook) == .lavender)
        let reloadedTints = Notebook()
        precondition(reloadedTints.tint(for: newBook) == .lavender)
        precondition(actions.notebookTints[actionBook.path] != nil)
        precondition(actions.root?.path == newBook.path)
        precondition(UserDefaults.standard.stringArray(forKey: "notebooks")?.contains(newBook.path) == true)
        precondition(actions.selected?.path == newBook.appendingPathComponent("Nested/CAFÉ copy 2.markdown").path)
        actions.edit("Saved before trash")
        let selectedBeforeTrash = actions.selected!
        guard let trashURL = try actions.trashItem(selectedBeforeTrash) else { preconditionFailure("Trash failed") }
        precondition(!FileManager.default.fileExists(atPath: selectedBeforeTrash.path))
        precondition((try? String(contentsOf: trashURL, encoding: .utf8)) == "Saved before trash")
        precondition(actions.selected != selectedBeforeTrash && !actions.dirty)
        // Restore only our own fixture, leaving the system Trash unchanged after the test.
        try FileManager.default.moveItem(at: trashURL, to: selectedBeforeTrash)
        guard let folderTrash = try actions.trashItem(folderCopy) else { preconditionFailure("Folder trash failed") }
        precondition(FileManager.default.fileExists(atPath: folderTrash.appendingPathComponent("Nested/CAFÉ.markdown").path))
        try FileManager.default.moveItem(at: folderTrash, to: folderCopy)
        actions.closeNotebook(newBook)
        precondition(!actions.notebooks.contains(newBook) && FileManager.default.fileExists(atPath: selectedBeforeTrash.path))
        print("PASS: note/folder/notebook rename, case-only names, extension preservation, collisions, invalid names, duplicate, folder promotion, trash and restore, close without deleting")

        // Terminate a separate process between its immediate draft and delayed autosave.
        let crashDir = root.appendingPathComponent("Crash fixture")
        try FileManager.default.createDirectory(at: crashDir, withIntermediateDirectories: false)
        let crashFile = crashDir.appendingPathComponent("Crash.md")
        try "Before crash".write(to: crashFile, atomically: true, encoding: .utf8)
        let child = Process(); child.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
        child.arguments = ["--recovery-fixture", crashDir.path]
        try child.run(); child.waitUntilExit(); precondition(child.terminationStatus == 73)
        precondition((try? String(contentsOf: crashFile, encoding: .utf8)) == "Before crash")
        let recovery = DraftRecovery(directory: crashDir.appendingPathComponent("Recovery"))
        let restored = try recovery.recover()
        precondition(restored == [crashFile])
        let crashText = try String(contentsOf: crashFile, encoding: .utf8)
        precondition(crashText == "# Survived\n\nUnflushed edits, Café 日本語 👋")
        let secondRecovery = try recovery.recover(); precondition(secondRecovery.isEmpty)
        // An outside edit survives too; the draft is recovered as a separate file.
        try recovery.checkpoint("My interrupted edit", original: crashText, file: crashFile)
        try "Outside edit".write(to: crashFile, atomically: true, encoding: .utf8)
        let conflictCopies = try recovery.recover()
        precondition(conflictCopies.count == 1 && conflictCopies[0] != crashFile)
        precondition((try? String(contentsOf: crashFile, encoding: .utf8)) == "Outside edit")
        precondition((try? String(contentsOf: conflictCopies[0], encoding: .utf8)) == "My interrupted edit")
        // A missing original also recovers separately, without silently resurrecting it.
        try recovery.checkpoint("Missing file draft", original: "Outside edit", file: crashFile)
        try FileManager.default.removeItem(at: crashFile)
        let missingCopies = try recovery.recover()
        precondition(missingCopies.count == 1 && !FileManager.default.fileExists(atPath: crashFile.path))
        precondition((try? String(contentsOf: missingCopies[0], encoding: .utf8)) == "Missing file draft")
        print("PASS: multiple notebooks, notebook persistence, keyboard note destination, cross-notebook moves, resized drag targets, zoom, abrupt-process recovery, conflicting and missing originals")
        print("PASS: file discovery, symlink loop exclusion, unique names, Unicode round-trip, autosave, external reload, new note, save before switching, file and folder moves, collision protection, cycle prevention, relative link rebasing")
    } catch { fatalError("Self-test failed: \(error)") }
}
