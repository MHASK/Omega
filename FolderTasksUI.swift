import SwiftUI
import WebKit

@MainActor final class FolderTasksBridge: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
    weak var notebook: Notebook?
    weak var webView: WKWebView?
    let folder: URL
    let files = EditorFiles()
    var ready = false
    var snapshot: FolderTaskSnapshot?
    var token = UUID().uuidString
    var saving = false
    var scanning = false
    var timer: Timer?
    var settings = ""
    var lastWarnings: [String] = []
    init(folder: URL, notebook: Notebook) { self.folder = folder; self.notebook = notebook }
    func start() { timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in Task { @MainActor in self?.refresh() } } }
    func stop() { timer?.invalidate(); timer = nil }
    func command(_ command: String) {
        guard ["undo", "redo", "find"].contains(command) else { return }
        let json = String(decoding: AssistantWire.json(["command": command]), as: UTF8.self)
        webView?.evaluateJavaScript("window.folio.command(\(json).command)", completionHandler: nil)
    }
    func synchronize(_ completion: @escaping (Bool) -> Void) {
        guard ready, let webView else { completion(true); return }
        func check(_ remaining: Int) {
            webView.evaluateJavaScript("window.folderTasks.flush()") { value, error in
                guard error == nil, let state = value as? [String: Any] else { completion(false); return }
                if state["pending"] as? Bool != true { completion(true); return }
                guard remaining > 0, state["failed"] as? Bool != true else { completion(false); return }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.04) { check(remaining - 1) }
            }
        }
        check(125)
    }
    func configure() {
        guard ready, let notebook, let webView else { return }
        webView.pageZoom = notebook.zoom
        let theme = notebook.appearance == "system" ? (webView.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? "dark" : "light") : notebook.appearance
        let tint = notebook.owner(of: folder).map { notebook.tint(for: $0).color } ?? Ink.muted
        var color = NSColor.gray
        NSAppearance(named: theme == "dark" ? .darkAqua : .aqua)!.performAsCurrentDrawingAppearance { color = tint.usingColorSpace(.sRGB) ?? .gray }
        let accent = String(format: "#%02x%02x%02x", Int(color.redComponent * 255), Int(color.greenComponent * 255), Int(color.blueComponent * 255))
        let config: [String: Any] = ["theme": theme, "accent": accent, "labels": notebook.labelColors, "taskHeaderInset": notebook.taskHeaderInset]
        let json = String(decoding: AssistantWire.json(config), as: UTF8.self)
        if json != settings { settings = json; webView.evaluateJavaScript("window.folderTasks.configure(\(json))", completionHandler: nil) }
    }
    func refresh() {
        guard ready, !saving, !scanning, let notebook, notebook.checklistFolder == folder, !notebook.gitSyncing else { return }
        guard notebook.owner(of: folder) != nil, !notebook.isArchived(folder) else { notice("This folder is no longer active."); return }
        scanning = true
        let archived = notebook.library.archived, preferences = notebook.taskPreferences, scannedFolder = folder
        let priorText = Dictionary(uniqueKeysWithValues: (snapshot?.sources ?? []).map { ($0.url, $0.text) })
        DispatchQueue.global(qos: .utility).async { [weak self] in
            var warnings: [String] = []
            let result = Result { () -> FolderTaskSnapshot in
                let sources = try NoteFiles.flatten(NoteFiles.scan(scannedFolder)).filter { entry in
                    !entry.isFolder && !archived.contains { entry.url.path == $0 || entry.url.path.hasPrefix($0 + "/") }
                }.compactMap { entry -> FolderTaskSource? in
                    do {
                        let info = try entry.url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
                        guard info.isRegularFile == true, (info.fileSize ?? 0) <= 8_000_000 else { throw TaskPageError("This page is too large to include.") }
                        let text = try String(contentsOf: entry.url, encoding: .utf8)
                        return try FolderTaskSource(url: entry.url, text: text, preferences: preferences)
                    } catch {
                        warnings.append(entry.url.deletingPathExtension().lastPathComponent + ": " + error.localizedDescription)
                        return priorText[entry.url].flatMap { try? FolderTaskSource(url: entry.url, text: $0, preferences: preferences) }
                    }
                }
                // Outside writers sometimes truncate then rewrite a file. Only
                // publish complete snapshots observed unchanged twice.
                Thread.sleep(forTimeInterval: 0.18)
                let stable = sources.compactMap { source -> FolderTaskSource? in
                    if (try? String(contentsOf: source.url, encoding: .utf8)) == source.text { return source }
                    warnings.append(source.url.lastPathComponent + " is being updated. Showing its last saved tasks.")
                    return priorText[source.url].flatMap { try? FolderTaskSource(url: source.url, text: $0, preferences: preferences) }
                }
                return try FolderTaskSnapshot(folder: scannedFolder, sources: stable, preferences: preferences)
            }
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }; self.scanning = false
                guard !self.saving, self.notebook?.checklistFolder == self.folder else { return }
                switch result {
                case .success(let next):
                    if self.snapshot?.sources.map(\.text) == next.sources.map(\.text), self.snapshot?.sources.map(\.url) == next.sources.map(\.url), FolderTaskSnapshot.equal(self.snapshot?.document, next.document), warnings == self.lastWarnings { return }
                    self.offer(next, warnings: warnings)
                case .failure(let error): self.notice(error.localizedDescription)
                }
            }
        }
    }
    func payload(_ snapshot: FolderTaskSnapshot, token: String, warnings: [String] = []) -> [String: Any] {
        ["token": token, "text": snapshot.document.markdown, "warnings": warnings,
         "sources": snapshot.sources.map { ["key": $0.key, "name": FolderTaskSnapshot.relative($0.url.deletingPathExtension(), from: folder), "taskPage": $0.inline == nil] as [String: Any] }]
    }
    func offer(_ next: FolderTaskSnapshot, warnings: [String]) {
        let nextToken = UUID().uuidString
        let json = String(decoding: AssistantWire.json(payload(next, token: nextToken, warnings: warnings)), as: UTF8.self)
        webView?.evaluateJavaScript("window.folderTasks.load(\(json))") { [weak self] accepted, error in
            guard let self else { return }
            if accepted as? Bool == true { self.snapshot = next; self.token = nextToken; self.lastWarnings = warnings; self.notebook?.restoreNavigation(in: self.webView, folder: true) }
            else if let error { self.notice("Could not display folder tasks: " + error.localizedDescription) }
        }
    }
    func notice(_ message: String) {
        let json = String(decoding: AssistantWire.json(["message": message]), as: UTF8.self)
        webView?.evaluateJavaScript("window.folderTasks.notice(\(json).message)", completionHandler: nil)
    }
    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.frameInfo.isMainFrame, let body = message.body as? [String: Any], let type = body["type"] as? String, let notebook else { return }
        switch type {
        case "ready": ready = true; configure(); refresh()
        case "change": save(body)
        case "back": if notebook.canGoBack { notebook.travelNavigation(forward: false) } else if let selected = notebook.selected { notebook.select(selected) }
        case "source":
            guard !saving, let key = body["source"] as? String, let source = snapshot?.sources.first(where: { $0.key == key }) else { return }
            if let id = body["item"] as? String, source.inline == nil,
               let ref = source.document.references.first(where: { $0.details.id == id }) { notebook.selectLinkedItem(source.url, kind: ref.kind, id: id) }
            else { notebook.select(source.url) }
        case "newPage": notebook.newTaskPage(in: folder)
        case "refresh": snapshot = nil; refresh()
        case "copy":
            if let text = body["text"] as? String { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text, forType: .string) }
        case "recover":
            if let text = body["text"] as? String { preserveDraft(text) }
        case "link":
            // Links belong to the task's source page, not the currently hidden note.
            guard let key = body["source"] as? String, let source = snapshot?.sources.first(where: { $0.key == key }), let href = body["url"] as? String else { return }
            if let url = URL(string: href), ["https", "http", "mailto"].contains(url.scheme ?? "") { NSWorkspace.shared.open(url) }
            else if let target = NoteLinks.resolve(href, from: source.url, roots: notebook.roots) {
                let fragment = URLComponents(string: href)?.fragment ?? ""
                if let kind = ["task", "goal"].first(where: { fragment.hasPrefix("folio-" + $0 + "-") }) { notebook.selectLinkedItem(target, kind: kind, id: String(fragment.dropFirst(kind.count + 7))) }
                else { notebook.select(target) }
            }
        case "references":
            guard let key = body["source"] as? String, let source = snapshot?.sources.first(where: { $0.key == key }), let request = body["request"] as? String, let links = body["links"] as? [String] else { return }
            let requestedFolder = notebook.checklistFolder
            LinkedContent.request(links, from: source.url, notebook: notebook, request: request) { [weak self] json in
                guard let self, self.notebook?.checklistFolder == requestedFolder else { return }
                self.webView?.evaluateJavaScript("(function(r){window.omegaReferences?.receive(r.request,r.rows)})(\(json))", completionHandler: nil)
            }
        case "pages":
            guard let key = body["source"] as? String, let current = snapshot?.sources.first(where: { $0.key == key }) else { return }
            let kind = body["kind"] as? String ?? "all"
            var pages: [[String: String]] = []
            for source in snapshot?.sources ?? [] {
                let href = NoteLinks.href(from: current.url, to: source.url)
                let location = FolderTaskSnapshot.relative(source.url.deletingPathExtension(), from: folder)
                if kind == "all" || kind == "page" { pages.append(["kind": "page", "name": source.url.deletingPathExtension().lastPathComponent, "location": location, "href": href]) }
                if source.inline == nil, kind != "page" {
                    for ref in source.document.references where ref.details.draft != true && (kind == "all" || (kind == "goal" ? ref.kind == "goal" : ref.kind != "goal")) {
                        // A link only targets a durable ID. Legacy items remain
                        // available by their page until their first task edit.
                        if let id = ref.details.id { pages.append(["kind": ref.kind, "name": ref.title, "location": location, "href": href + "#folio-" + (ref.kind == "goal" ? "goal" : "task") + "-" + id]) }
                    }
                }
            }
            webView?.evaluateJavaScript("window.folderTasks.pages(\(String(decoding: AssistantWire.json(pages), as: UTF8.self)))", completionHandler: nil)
        default: break
        }
    }
    func save(_ body: [String: Any]) {
        guard let notebook, !saving, let baseline = snapshot, body["token"] as? String == token, let text = body["text"] as? String else { reject("The folder changed. Your pending edit is kept here; reload to see the latest pages."); return }
        preserveDraft(text)
        saving = true
        let perform = {
            do {
                try notebook.prepareAssistantAccess()
                let desired = try TaskDocument(markdown: text), edits = try baseline.edits(desired)
                let service = AssistantService(notebook)
                // Validate all affected pages before beginning a multi-page change.
                for edit in edits {
                    _ = try service.resolve(edit.url.path, folder: false)
                    guard !notebook.isArchived(edit.url), try String(contentsOf: edit.url, encoding: .utf8) == edit.before else { throw TaskPageError(edit.url.deletingPathExtension().lastPathComponent + " changed outside this view. Reload before trying this edit again.") }
                }
                self.write(edits, at: 0, baseline: baseline, saved: [], service: service)
            } catch { self.saving = false; self.reject(error.localizedDescription) }
        }
        if let editor = notebook.richEditor { editor.synchronize { success in
            if success { perform() } else { self.saving = false; self.reject("The open page is still saving. Try again in a moment.") }
        }} else { perform() }
    }
    private func write(_ edits: [FolderTaskSnapshot.Edit], at index: Int, baseline: FolderTaskSnapshot, saved: [URL], service: AssistantService) {
        guard let notebook else { return }
        if index == edits.count {
            do {
                let sources = try baseline.sources.map { source in
                    try FolderTaskSource(url: source.url, text: edits.first { $0.url == source.url }?.after ?? source.text, preferences: notebook.taskPreferences)
                }
                let next = try FolderTaskSnapshot(folder: folder, sources: sources, preferences: notebook.taskPreferences)
                snapshot = next; token = UUID().uuidString; saving = false
                let response = ["token": token]
                webView?.evaluateJavaScript("window.folderTasks.saved(\(String(decoding: AssistantWire.json(response), as: UTF8.self)))", completionHandler: nil)
            } catch { saving = false; reject(error.localizedDescription) }
            return
        }
        let edit = edits[index]
        do {
            try service.update(["path": edit.url.path, "expected_revision": AssistantWire.hash(edit.before), "markdown": edit.after]) { [weak self] result in
                guard let self else { return }
                if result["isError"] as? Bool == true {
                    self.saving = false
                    let message = (result["content"] as? [[String: Any]])?.first?["text"] as? String ?? "Could not save this change."
                    self.reject(message + (saved.isEmpty ? "" : " Changes already saved in: " + saved.map(\.lastPathComponent).joined(separator: ", ") + ". Reload to continue."))
                } else { self.write(edits, at: index + 1, baseline: baseline, saved: saved + [edit.url], service: service) }
            }
        } catch { saving = false; reject(error.localizedDescription + (saved.isEmpty ? "" : " Some pages were saved. Reload to continue.")) }
    }
    func preserveDraft(_ text: String) {
        // Failed multi-page proposals are recoverable even after leaving the view.
        guard let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return }
        let directory = base.appendingPathComponent("Omega/Folder task recovery", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let file = directory.appendingPathComponent(String(FolderTaskSnapshot.hash(folder.path).prefix(16)) + ".md")
            try DraftRecovery.write(text, to: file)
        } catch { notice("The folder change could not be backed up: " + error.localizedDescription) }
    }
    func reject(_ message: String) {
        let json = String(decoding: AssistantWire.json(["message": message]), as: UTF8.self)
        webView?.evaluateJavaScript("window.folderTasks.failed(\(json).message)", completionHandler: nil)
    }
    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        decisionHandler(action.request.url?.absoluteString == "folio://app/folder-tasks.html" ? .allow : .cancel)
    }
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) { ready = false; snapshot = nil; webView.reload() }
}

struct FolderTasksEditor: NSViewRepresentable {
    let folder: URL
    @ObservedObject var notebook: Notebook
    func makeCoordinator() -> FolderTasksBridge { FolderTasksBridge(folder: folder, notebook: notebook) }
    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration(); config.websiteDataStore = .nonPersistent()
        config.setURLSchemeHandler(context.coordinator.files, forURLScheme: "folio")
        config.userContentController.add(context.coordinator, name: "folderTasks")
        let view = WKWebView(frame: .zero, configuration: config)
        view.setValue(false, forKey: "drawsBackground"); view.navigationDelegate = context.coordinator
        context.coordinator.webView = view; notebook.folderTasksEditor = context.coordinator; context.coordinator.start()
        view.load(URLRequest(url: URL(string: "folio://app/folder-tasks.html")!)); return view
    }
    func updateNSView(_ view: WKWebView, context: Context) { context.coordinator.configure() }
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: WKWebView, context: Context) -> CGSize? { CGSize(width: proposal.width ?? 0, height: proposal.height ?? 0) }
    static func dismantleNSView(_ view: WKWebView, coordinator: FolderTasksBridge) { coordinator.stop(); if coordinator.notebook?.folderTasksEditor === coordinator { coordinator.notebook?.folderTasksEditor = nil }; view.configuration.userContentController.removeScriptMessageHandler(forName: "folderTasks") }
}
