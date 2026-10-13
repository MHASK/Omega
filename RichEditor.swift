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
        let settings = "\(theme)|\(notebook.zoom)|\(notebook.reading)|\(accent)|\(labelConfig)|\(notebook.writingScale)|\(notebook.writingFont)|\(notebook.writingWide)"
        if loadedID == identity && settings == lastConfiguration { revealPending(); revealItemPending(); return }
        let config: [String: Any] = ["id": identity, "text": notebook.text, "theme": theme, "zoom": notebook.zoom, "reading": notebook.reading, "accent": accent, "labelColors": notebook.labelColors, "writingScale": notebook.writingScale, "writingFont": notebook.writingFont, "writingWide": notebook.writingWide, "author": NSFullUserName(), "nativeHeader": true]
        guard let data = try? JSONSerialization.data(withJSONObject: config), let json = String(data: data, encoding: .utf8) else { return }
        if loadedID != identity {
            LiveCollaboration.shared.stop()
            loadedID = identity; loadedReadyID = ""; lastConfiguration = settings
            let requestedID = identity
            webView.evaluateJavaScript("window.folio.load(\(json))") { [weak self] _, error in
                if let error { self?.notebook?.showError(error) }
                else if let self, self.identity == requestedID {
                    self.loadedReadyID = requestedID
                    LiveCollaboration.shared.prepare(self)
                    self.revealItemPending()
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
        guard ready, let webView else { completion(true); return }
        webView.evaluateJavaScript("window.folio.snapshot()") { [weak self] value, error in
            guard let self else { completion(true); return }
            if let error { self.notebook?.showError(error); completion(false); return }
            if let snapshot = value as? [String: Any], snapshot["id"] as? String == self.identity, let text = snapshot["text"] as? String, text != self.notebook?.text { self.notebook?.edit(text) }
            completion(true)
        }
    }
    func replaceForAssistant(expected: String, text: String, completion: @escaping (Result<Void, Error>) -> Void) {
        guard ready, loadedReadyID == identity, let webView else { completion(.failure(AssistantError("The editor is loading. Retry shortly."))); return }
        let config = ["id": identity, "expected": expected, "text": text]
        let data = try! JSONSerialization.data(withJSONObject: config)
        let json = String(decoding: data, as: UTF8.self)
        webView.evaluateJavaScript("window.folio.replaceForAssistant(\(json))") { result, error in
            if let error { completion(.failure(error)) }
            else if result as? Bool == true { completion(.success(())) }
            else { completion(.failure(AssistantError("Conflict: the note changed or is in an active editing dialog. Read it again before updating."))) }
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
                    if kind != "page", entry.isTaskPage {
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
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        ready = false; loadedID = ""; loadedReadyID = ""; webView.reload()
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
