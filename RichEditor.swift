import SwiftUI
import WebKit
import UniformTypeIdentifiers

final class EditorFiles: NSObject, WKURLSchemeHandler {
    var note: URL?
    var root: URL?
    func webView(_ webView: WKWebView, start task: WKURLSchemeTask) {
        guard let request = task.request.url else { return }
        do {
            let base: URL
            let relative: String
            if request.host == "app" {
                base = Bundle.main.resourceURL!
                relative = String(request.path.dropFirst())
            } else if request.host == "asset", let note, let root {
                base = root.resolvingSymlinksInPath()
                let name = String(request.path.dropFirst()).removingPercentEncoding ?? String(request.path.dropFirst())
                let candidate = note.deletingLastPathComponent().appendingPathComponent(name).standardizedFileURL.resolvingSymlinksInPath()
                guard candidate.path.hasPrefix(base.path + "/"), ["png", "jpg", "jpeg", "webp", "gif", "svg", "heic", "tiff", "bmp"].contains(candidate.pathExtension.lowercased()) else { throw CocoaError(.fileReadNoPermission) }
                relative = String(candidate.path.dropFirst(base.path.count + 1))
            } else { throw CocoaError(.fileReadNoPermission) }
            let file = base.appendingPathComponent(relative).standardizedFileURL.resolvingSymlinksInPath()
            guard file.path.hasPrefix(base.path + "/") else { throw CocoaError(.fileReadNoPermission) }
            let size = try file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            guard size < 30_000_000 else { throw CocoaError(.fileReadTooLarge) }
            let data = try Data(contentsOf: file)
            let special = ["js": "text/javascript", "css": "text/css", "html": "text/html", "svg": "image/svg+xml", "woff2": "font/woff2", "ttf": "font/ttf"]
            let mime = special[file.pathExtension] ?? UTType(filenameExtension: file.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
            task.didReceive(URLResponse(url: request, mimeType: mime, expectedContentLength: data.count, textEncodingName: mime.hasPrefix("text/") ? "utf-8" : nil))
            task.didReceive(data); task.didFinish()
        } catch { task.didFailWithError(error) }
    }
    func webView(_ webView: WKWebView, stop task: WKURLSchemeTask) {}
}

@MainActor
final class EditorBridge: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
    weak var notebook: Notebook?
    weak var webView: WKWebView?
    let files = EditorFiles()
    var ready = false
    private var loadedID = ""
    private var loadedReadyID = ""
    private var pendingLoadID: String?
    private var lastReveal: UUID?
    private var pendingItem: (url: URL, kind: String, id: String)?
    private var lastConfiguration = ""
    init(_ notebook: Notebook) { self.notebook = notebook }
    var identity: String { guard let notebook else { return "" }; return (notebook.selected?.path ?? "") + "|" + notebook.revision.uuidString }
    func update() {
        guard ready, let notebook, let webView else { return }
        files.note = notebook.selected; files.root = notebook.root
        if webView.pageZoom != notebook.zoom { webView.pageZoom = notebook.zoom }
        let theme = notebook.appearance == "system" ? (webView.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? "dark" : "light") : notebook.appearance
        let tint = notebook.selected.flatMap { notebook.owner(of: $0) }.map { notebook.tint(for: $0).color } ?? Ink.muted
        var resolved = NSColor.gray
        NSAppearance(named: theme == "dark" ? .darkAqua : .aqua)!.performAsCurrentDrawingAppearance { resolved = tint.usingColorSpace(.sRGB) ?? .gray }
        let accent = String(format: "#%02x%02x%02x", Int(resolved.redComponent * 255), Int(resolved.greenComponent * 255), Int(resolved.blueComponent * 255))
        let labelConfig = String(decoding: (try? JSONSerialization.data(withJSONObject: notebook.labelColors, options: [.sortedKeys])) ?? Data(), as: UTF8.self)
        let settings = "\(theme)|\(notebook.zoom)|\(notebook.reading)|\(accent)|\(labelConfig)|\(notebook.writingScale)|\(notebook.writingFont)|\(notebook.writingWide)|\(notebook.taskHeaderInset)"
        if loadedID == identity && settings == lastConfiguration { revealPending(); revealItemPending(); notebook.restoreNavigation(in: webView, folder: false); return }
        let config: [String: Any] = ["id": identity, "text": notebook.text, "theme": theme, "zoom": notebook.zoom, "reading": notebook.reading, "accent": accent, "labelColors": notebook.labelColors, "writingScale": notebook.writingScale, "writingFont": notebook.writingFont, "writingWide": notebook.writingWide, "author": NSFullUserName(), "nativeHeader": true, "taskHeaderInset": notebook.taskHeaderInset]
        guard let data = try? JSONSerialization.data(withJSONObject: config), let json = String(data: data, encoding: .utf8) else { return }
        if loadedID != identity {
            LiveCollaboration.shared.stop()
            loadedID = identity; loadedReadyID = ""; lastConfiguration = settings
            let requestedID = identity
            pendingLoadID = requestedID
            // SwiftUI may call update() while laying out this representable.
            // Publish loading state on the next turn, and ignore stale requests.
            DispatchQueue.main.async { [weak self] in
                guard let self, self.identity == requestedID, self.pendingLoadID == requestedID else { return }
                self.notebook?.editorLoading = true; self.notebook?.editorLoadError = nil
            }
            webView.evaluateJavaScript("window.folio.load(\(json))") { [weak self] _, error in
                guard let self, self.identity == requestedID else { return }
                self.pendingLoadID = nil
                if let error {
                    self.notebook?.editorLoading = false
                    self.notebook?.editorLoadError = error.localizedDescription
                } else {
                    self.loadedReadyID = requestedID
                    self.notebook?.editorLoading = false; self.notebook?.editorLoadError = nil
                    LiveCollaboration.shared.prepare(self)
                    self.revealItemPending()
                    self.notebook?.restoreNavigation(in: webView, folder: false)
                    if self.notebook?.searchReveal != nil { self.revealPending() }
                    else if self.notebook?.text.isEmpty == true { self.focus() }
                }
            }
        } else {
            if settings != lastConfiguration {
                lastConfiguration = settings
                webView.evaluateJavaScript("window.folio.configure(\(json))", completionHandler: nil)
            }
        }
        revealPending()
    }
    func queueItem(_ url: URL, kind: String, id: String) {
        pendingItem = (url, kind, id); update(); revealItemPending()
    }
    private func revealItemPending() {
        guard loadedReadyID == identity, let pending = pendingItem, pending.url == notebook?.selected, let webView else { return }
        pendingItem = nil
        let config = ["id": identity, "kind": pending.kind, "item": pending.id]
        webView.evaluateJavaScript("window.folio.revealItem(\(String(decoding: AssistantWire.json(config), as: UTF8.self)))") { [weak self] value, error in
            if let error { self?.notebook?.showError(error) }
            else if value as? Bool != true { self?.notebook?.showMessage("This task or goal is no longer on this page.") }
        }
    }
    private func revealPending() {
        guard loadedReadyID == identity, let notebook, let reveal = notebook.searchReveal,
              reveal.url == notebook.selected, lastReveal != reveal.id, let webView else { return }
        guard let data = try? JSONEncoder().encode(reveal.anchor), let anchor = String(data: data, encoding: .utf8),
              let idData = try? JSONSerialization.data(withJSONObject: [identity]), let id = String(data: idData, encoding: .utf8) else { return }
        lastReveal = reveal.id
        webView.window?.makeFirstResponder(webView)
        webView.evaluateJavaScript("window.folio.revealMatch({id: \(id)[0], anchor: \(anchor)})") { [weak self] _, error in
            guard let self else { return }
            if self.notebook?.searchReveal?.id == reveal.id { self.notebook?.searchReveal = nil }
            if let error { self.notebook?.showError(error) }
        }
    }
    func synchronize(_ completion: @escaping (Bool) -> Void) {
        // A failed or pending load may contain a partial model from the prior
        // note. Only a successfully loaded identity can supply edits to save.
        guard ready, loadedReadyID == identity, let webView else { completion(true); return }
        let requestedID = identity
        var finished = false
        let finish: (Bool) -> Void = { success in
            guard !finished else { return }; finished = true; completion(success)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 8) { finish(false) }
        webView.evaluateJavaScript("window.folio.snapshot()") { [weak self] value, error in
            guard !finished else { return }
            guard let self, self.identity == requestedID else { finish(false); return }
            guard error == nil else { finish(false); return }
            guard let snapshot = value as? [String: Any], snapshot["id"] as? String == requestedID,
                  let text = snapshot["text"] as? String else { finish(false); return }
            if text != self.notebook?.text { self.notebook?.edit(text) }
            finish(true)
        }
    }

    func replaceForAssistant(expected: String, text: String, completion: @escaping (Result<Void, Error>) -> Void) {
        guard ready, loadedReadyID == identity, let webView else { completion(.failure(AssistantError("The editor is loading. Retry shortly."))); return }
        let requestedID = identity
        let config: [String: Any] = ["id": requestedID, "expected": expected, "text": text, "activity": true]
        let data = try! JSONSerialization.data(withJSONObject: config)
        let json = String(decoding: data, as: UTF8.self)
        webView.evaluateJavaScript("window.folio.replaceForAssistant(\(json))") { [weak self] result, error in
            if self?.identity != requestedID { completion(.failure(AssistantError("The selected note changed. Read the note again before editing."))) }
            else if let error { completion(.failure(error)) }
            else if result as? Bool == true { completion(.success(())) }
            else { completion(.failure(AssistantError("Conflict: the note changed or is in an active editing dialog. Read it again before updating."))) }
        }
    }
    func applyExternal(base: String, text: String, completion: @escaping ([String: Any]) -> Void) {
        guard ready, loadedReadyID == identity, let webView else { completion(["status": "deferred"]); return }
        let requestedID = identity
        let config = ["id": requestedID, "base": base, "text": text]
        let json = String(decoding: try! JSONSerialization.data(withJSONObject: config), as: UTF8.self)
        webView.evaluateJavaScript("window.folio.applyExternal(\(json))") { [weak self] value, _ in
            guard self?.identity == requestedID else { completion(["status": "deferred"]); return }
            completion(value as? [String: Any] ?? ["status": "deferred"])
        }
    }
    func command(_ command: String) {
        let data = try! JSONSerialization.data(withJSONObject: [command])
        let json = String(data: data, encoding: .utf8)!
        webView?.evaluateJavaScript("window.folio.command(\(json)[0])", completionHandler: nil)
    }
    func focus() { webView?.window?.makeFirstResponder(webView); webView?.evaluateJavaScript("window.folio.focus()", completionHandler: nil) }
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.frameInfo.isMainFrame, let body = message.body as? [String: Any], let type = body["type"] as? String, let notebook else { return }
        switch type {
        case "liveReady", "liveCheckpoint", "liveConflict", "liveAwareness": LiveCollaboration.shared.handle(body, editor: self)
        case "liveNotice": notebook.showMessage(body["message"] as? String ?? "Live editing is active")
        case "ready": ready = true; update()
        case "change":
            if body["id"] as? String == identity, let text = body["text"] as? String, text != notebook.text {
                notebook.edit(text, beforeSelection: body["beforeSelection"] as? String ?? "", afterSelection: body["afterSelection"] as? String ?? "", typing: body["typing"] as? Bool ?? false)
            }
        case "history":
            guard let id = body["id"] as? String else { return }
            var response: [String: Any] = ["id": id]
            if id == identity {
                if let text = body["text"] as? String, text != notebook.text { notebook.edit(text) }
                do {
                    if let result = try notebook.stepHistory(redo: body["redo"] as? Bool ?? false) {
                        response["text"] = result.text; response["selection"] = result.selection
                    }
                } catch { notebook.showError(error) }
            }
            if let data = try? JSONSerialization.data(withJSONObject: response), let json = String(data: data, encoding: .utf8) {
                webView?.evaluateJavaScript("window.folio.historyResult(\(json))", completionHandler: nil)
            }
        case "cursor": if body["id"] as? String == identity { notebook.cursorLine = body["line"] as? Int ?? 1; notebook.cursorColumn = body["column"] as? Int ?? 1 }
        case "zoom": notebook.changeZoom(body["direction"] as? Int ?? 0)
        case "writingPreferences":
            guard body["id"] as? String == identity else { return }
            notebook.setWriting(scale: body["scale"] as? Double, font: body["font"] as? String, wide: body["wide"] as? Bool)
        case "writingState":
            guard body["id"] as? String == identity else { return }
            notebook.documentComments = body["comments"] as? Int ?? 0
            notebook.documentIsSource = body["source"] as? Bool ?? false
        case "writingZoom": notebook.changeWritingSize(body["direction"] as? Int ?? 0)
        case "image": chooseImage()
        case "references":
            guard body["id"] as? String == identity, let source = notebook.selected, let request = body["request"] as? String, let hrefs = body["links"] as? [String] else { return }
            let requestedID = identity
            LinkedContent.request(hrefs, from: source, notebook: notebook, request: request) { [weak self] json in
                guard let self, self.identity == requestedID else { return }
                self.webView?.evaluateJavaScript("(function(r){window.omegaReferences?.receive(r.request,r.rows)})(\(json))", completionHandler: nil)
            }
        case "pages":
            guard body["id"] as? String == identity, let request = body["request"] as? String, let note = notebook.selected else { return }
            var seen = Set<String>(), pages: [[String: String]] = []
            let kind = body["kind"] as? String ?? "page"
            for root in notebook.roots {
                for entry in NoteFiles.flatten(notebook.trees[root] ?? (root == notebook.root ? notebook.entries : [])) where !entry.isFolder && !notebook.isArchived(entry.url) && seen.insert(entry.url.path).inserted {
                    let folder = entry.url.deletingLastPathComponent()
                    let subpath = String(folder.path.dropFirst(root.path.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                    let location = root.lastPathComponent + (subpath.isEmpty ? "" : " / " + subpath)
                    let href = NoteLinks.href(from: note, to: entry.url)
                    if (kind == "all" || kind == "page") && entry.url != note { pages.append(["name": entry.name, "location": location, "href": href, "kind": "page"]) }
                    if kind == "section", entry.url != note, let size = try? entry.url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size < 500_000,
                       let text = try? String(contentsOf: entry.url, encoding: .utf8) {
                        pages.append(["name": entry.name, "location": location + " / Entire page", "href": href, "kind": "page"])
                        let headings = LinkedContent.headings(text)
                        for heading in headings where headings.filter({ $0.title == heading.title }).count == 1 {
                            pages.append(["name": heading.title, "location": location + " / " + entry.name, "href": LinkedContent.sectionHref(href, title: heading.title), "kind": "page"])
                        }
                    }
                    if kind != "page" && kind != "section", entry.isTaskPage {
                        guard let text = entry.url == note ? notebook.text : (try? String(contentsOf: entry.url, encoding: .utf8)), let document = try? TaskDocument(markdown: text) else { continue }
                        let revision = AssistantWire.hash(text)
                        for ref in document.references where ref.details.draft != true && (kind == "all" || (kind == "goal" ? ref.kind == "goal" : ref.kind != "goal")) {
                            pages.append(["name": ref.title.isEmpty ? "Untitled " + ref.kind : ref.title, "kind": ref.kind, "location": location + " / " + document.title + (ref.kind == "subtask" ? " / " + ref.parent : ""), "href": href, "reference": ref.reference, "revision": revision, "current": entry.url == note ? "true" : "false"])
                        }
                    }
                }
            }
            if let data = try? JSONSerialization.data(withJSONObject: ["id": identity, "request": request, "pages": pages]) {
                webView?.evaluateJavaScript("window.folio.pageResults(\(String(decoding: data, as: UTF8.self)))", completionHandler: nil)
            }
        case "prepareItemLink":
            guard body["id"] as? String == identity, let request = body["request"] as? String, let source = notebook.selected,
                  let href = body["href"] as? String, let reference = body["reference"] as? String else { return }
            var response: [String: Any] = ["id": identity, "request": request]
            do {
                guard let target = NoteLinks.resolve(href, from: source, roots: notebook.roots), target != source else { throw TaskPageError("Choose this item again.") }
                let previous = try String(contentsOf: target, encoding: .utf8)
                guard AssistantWire.hash(previous) == body["revision"] as? String else { throw TaskPageError("This page changed. Close the picker and choose the item again.") }
                var document = try TaskDocument(markdown: previous)
                guard let ref = document.references.first(where: { $0.reference == reference }) else { throw TaskPageError("This item is no longer available.") }
                let stableID = try document.ensureLinkID(reference)
                if ref.details.id == nil {
                    _ = try AssistantService(notebook).backup(target, text: previous)
                    guard (try String(contentsOf: target, encoding: .utf8)) == previous else { throw TaskPageError("This page changed. Choose the item again.") }
                    try notebook.acceptAssistantText(document.markdown, at: target)
                }
                response["page"] = ["name": ref.title.isEmpty ? "Untitled " + ref.kind : ref.title, "href": NoteLinks.href(from: source, to: target) + "#folio-" + (ref.kind == "goal" ? "goal" : "task") + "-" + stableID]
            } catch { response["error"] = error.localizedDescription }
            webView?.evaluateJavaScript("window.folio.linkReady(\(String(decoding: AssistantWire.json(response), as: UTF8.self)))", completionHandler: nil)
        case "link":
            guard body["id"] as? String == identity, let raw = body["url"] as? String else { return }
            if let url = URL(string: raw), ["https", "http", "mailto"].contains(url.scheme?.lowercased() ?? "") { NSWorkspace.shared.open(url) }
            else if let source = notebook.selected {
                if let target = NoteLinks.resolve(raw, from: source, roots: notebook.roots) {
                    let fragment = URLComponents(string: raw)?.fragment ?? ""
                    if let kind = ["task", "goal"].first(where: { fragment.hasPrefix("folio-" + $0 + "-") }) {
                        notebook.selectLinkedItem(target, kind: kind, id: String(fragment.dropFirst(kind.count + 7)))
                    } else { notebook.select(target) }
                }
                else { notebook.showMessage("This linked note isn't available. It may have moved, or its notebook may be closed.") }
            }
        default: break
        }
    }
    func chooseImage() {
        guard let note = notebook?.selected else { return }
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.image]; panel.prompt = "Insert image"
        guard panel.runModal() == .OK, let image = panel.url else { return }
        do {
            let assets = note.deletingLastPathComponent().appendingPathComponent("assets")
            try FileManager.default.createDirectory(at: assets, withIntermediateDirectories: true)
            let name = image.deletingPathExtension().lastPathComponent + "-" + UUID().uuidString.prefix(6) + "." + image.pathExtension
            let destination = assets.appendingPathComponent(name)
            try FileManager.default.copyItem(at: image, to: destination)
            let data = try JSONSerialization.data(withJSONObject: ["assets/" + name])
            let json = String(data: data, encoding: .utf8)!
            webView?.evaluateJavaScript("window.folio.insertImage(\(json)[0])", completionHandler: nil)
        } catch { notebook?.showError(error) }
    }
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        decisionHandler(navigationAction.request.url?.host == "app" && navigationAction.request.url?.scheme == "folio" ? .allow : .cancel)
    }
    func retryLoad() {
        ready = false; loadedID = ""; loadedReadyID = ""; pendingLoadID = nil
        notebook?.editorLoading = true; notebook?.editorLoadError = nil
        webView?.reload()
    }
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) { retryLoad() }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        webView.evaluateJavaScript("typeof window.folio?.load === 'function'") { [weak self] result, error in
            guard let self, !self.ready else { return }
            if let error { self.loadingFailed(error) }
            else if result as? Bool != true { self.loadingFailed(AssistantError("The editor resources could not be loaded. Try opening the editor again.")) }
        }
    }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { loadingFailed(error) }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { loadingFailed(error) }
    private func loadingFailed(_ error: Error) {
        guard (error as NSError).code != NSURLErrorCancelled else { return }
        ready = false; notebook?.editorLoading = false; notebook?.editorLoadError = error.localizedDescription
    }
}

struct RichEditor: NSViewRepresentable {
    @ObservedObject var notebook: Notebook
    func makeCoordinator() -> EditorBridge { EditorBridge(notebook) }
    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        config.setURLSchemeHandler(context.coordinator.files, forURLScheme: "folio")
        config.userContentController.add(context.coordinator, name: "folio")
        let view = WKWebView(frame: .zero, configuration: config)
        view.setValue(false, forKey: "drawsBackground")
        view.navigationDelegate = context.coordinator
        view.allowsBackForwardNavigationGestures = false
        context.coordinator.webView = view
        notebook.richEditor = context.coordinator
        view.load(URLRequest(url: URL(string: "folio://app/index.html")!))
        return view
    }
    func updateNSView(_ view: WKWebView, context: Context) { context.coordinator.update() }
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: WKWebView, context: Context) -> CGSize? {
        // The editor follows its pane; document content must never size the window.
        CGSize(width: proposal.width ?? 0, height: proposal.height ?? 0)
    }
    static func dismantleNSView(_ view: WKWebView, coordinator: EditorBridge) {
        LiveCollaboration.shared.stop()
        view.configuration.userContentController.removeScriptMessageHandler(forName: "folio")
        if coordinator.notebook?.richEditor === coordinator { coordinator.notebook?.richEditor = nil }
    }
}

// Read-only projections. A reference never copies the source into the quoting
// note or rewrites the user's table. All paths use the normal notebook boundary.
enum LinkedContent {
    struct Snapshot {
        let roots: [URL]
        let archived: Set<String>
        let selected: URL?
        let text: String
        let preferences: TaskPreferences
        let files: [URL]
        func isArchived(_ url: URL) -> Bool { archived.contains { url.path == $0 || url.path.hasPrefix($0 + "/") } }
        func owner(of url: URL) -> URL? { roots.filter { url.path.hasPrefix($0.path + "/") }.max { $0.path.count < $1.path.count } }
        @MainActor init(_ notebook: Notebook) {
            roots = notebook.roots; archived = notebook.library.archived; selected = notebook.selected
            text = notebook.text; preferences = notebook.taskPreferences
            files = roots.flatMap { NoteFiles.flatten(notebook.trees[$0] ?? []) }.filter { !$0.isFolder }.map(\.url)
        }
    }
    // Parsing linked pages must never occupy the UI/MCP actor. Capture only values;
    // background work cannot read or mutate the live notebook or editor.
    @MainActor static func request(_ hrefs: [String], from source: URL, notebook: Notebook, request: String, completion: @escaping (String) -> Void) {
        let snapshot = Snapshot(notebook)
        DispatchQueue.global(qos: .utility).async {
            let response: [String: Any] = ["request": request, "rows": rows(hrefs, from: source, snapshot: snapshot)]
            let json = String(decoding: AssistantWire.json(response), as: UTF8.self)
            DispatchQueue.main.async { completion(json) }
        }
    }
    static func headings(_ text: String) -> [(line: Int, level: Int, title: String)] {
        var result: [(Int, Int, String)] = [], fence: Character?
        for (i, line) in text.components(separatedBy: "\n").enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                if fence == trimmed.first { fence = nil } else if fence == nil { fence = trimmed.first }
                continue
            }
            guard fence == nil else { continue }
            let hashes = line.prefix { $0 == "#" }.count
            guard (1...6).contains(hashes), line.dropFirst(hashes).first == " " else { continue }
            let title = line.dropFirst(hashes + 1).trimmingCharacters(in: .whitespaces)
            if !title.isEmpty { result.append((i, hashes, title)) }
        }
        return result
    }
    static func sectionHref(_ href: String, title: String) -> String {
        href + "#omega-section-" + (title.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? "")
    }
    static func rows(_ hrefs: [String], from source: URL, snapshot: Snapshot) -> [[String: Any]] {
        var cache: [URL: String] = [:], documents: [URL: TaskDocument] = [:]
        var parsed = Set<URL>()
        func parsedDocument(_ url: URL, _ text: String) -> TaskDocument? {
            if parsed.insert(url).inserted {
                documents[url] = TaskDocument.isTaskPage(text) ? try? TaskDocument(markdown: text) : try? InlineTaskDocument(text, preferences: snapshot.preferences).document
            }
            return documents[url]
        }
        return Array(Set(hrefs)).sorted().prefix(100).map { href in
            var row: [String: Any] = ["href": href]
            do {
                guard href.count < 4096, let url = NoteLinks.resolve(href, from: source, roots: snapshot.roots), !snapshot.isArchived(url) else { throw TaskPageError("Source page is unavailable.") }
                let values = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
                guard values.isRegularFile == true, (values.fileSize ?? 0) < 500_000 else { throw TaskPageError("This source is too large to preview.") }
                let text: String
                if let cached = cache[url] { text = cached }
                else { text = url == snapshot.selected ? snapshot.text : try String(contentsOf: url, encoding: .utf8); cache[url] = text }
                var excerpt = text, name = url.deletingPathExtension().lastPathComponent
                if let fragment = href.split(separator: "#", maxSplits: 1).dropFirst().first, fragment.hasPrefix("omega-section-") {
                    let heading = String(fragment.dropFirst(14)).removingPercentEncoding ?? ""
                    let entries = headings(text), matches = entries.filter { $0.title == heading }
                    guard matches.count == 1, let entry = matches.first else { throw TaskPageError("This heading was renamed, removed, or is no longer unique. Choose its source again.") }
                    let lines = text.components(separatedBy: "\n")
                    let end = entries.first { $0.line > entry.line && $0.level <= entry.level }?.line ?? lines.count
                    excerpt = lines[(entry.line + 1)..<end].joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
                    name += " / " + heading
                }
                row["name"] = name; row["markdown"] = excerpt
                if let fragment = href.split(separator: "#", maxSplits: 1).dropFirst().first, fragment.hasPrefix("folio-goal-"),
                   let document = parsedDocument(url, text), let goal = document.goals.first(where: { $0.details.id == String(fragment.dropFirst(11)) }) {
                    let own = document.goalProgress(goal)
                    var total = own.linked.count, completed = own.completed
                    if let owner = snapshot.owner(of: url) {
                        for file in snapshot.files where file != url && snapshot.owner(of: file) == owner && !snapshot.isArchived(file) {
                            guard let size = try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize, size < 500_000 else { continue }
                            let otherText: String
                            if let cached = cache[file] { otherText = cached }
                            else if let read = try? String(contentsOf: file, encoding: .utf8) { otherText = read; cache[file] = read }
                            else { continue }
                            guard otherText.contains("omegaGoalSources") else { continue }
                            let other = parsedDocument(file, otherText)
                            guard let other else { continue }
                            for ref in other.references where ref.kind != "goal" && ref.details.draft != true {
                                guard case .object(let links) = ref.details.extra["omegaGoalSources"] else { continue }
                                let linked = (ref.details.goals ?? []).contains { alias in
                                    guard case .object(let link) = links[alias], case .string(let path) = link["path"], case .string(let id) = link["id"] else { return false }
                                    return id == goal.details.id && file.deletingLastPathComponent().appendingPathComponent(path).standardizedFileURL == url.standardizedFileURL
                                }
                                if linked { total += 1; if other.isCompleted(ref.status) { completed += 1 } }
                            }
                        }
                    }
                    let done = total > 0 ? completed == total : goal.completed
                    row["goalProgress"] = ["name": goal.title, "total": max(1, total), "completed": total > 0 ? completed : (done ? 1 : 0), "status": done ? "Done" : completed > 0 ? "In progress" : "Not started"]
                }
                if let parsed = parsedDocument(url, text), !parsed.tasks.isEmpty || !parsed.goals.isEmpty {
                    row["tasks"] = TaskDocument.isTaskPage(text) ? text : parsed.markdown
                }
            } catch { row["error"] = error.localizedDescription }
            return row
        }
    }
}
