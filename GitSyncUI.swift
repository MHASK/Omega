import SwiftUI
import WebKit

// Reuse Omega's actual editor schema for rich text, comments and task records.
// The scratch web view is offline and never joins the relay.
@MainActor final class GitCheckpointMerger {
    private var view: WKWebView?
    private let files = EditorFiles()
    func merge(mine: LiveCheckpoint, incoming: LiveCheckpoint? = nil, mineText: String? = nil, incomingText: String? = nil, resolvedText: String? = nil) async throws -> LiveCheckpoint? {
        if view == nil {
            let config = WKWebViewConfiguration(); config.websiteDataStore = .nonPersistent(); config.setURLSchemeHandler(files, forURLScheme: "folio")
            let web = WKWebView(frame: NSRect(x: 0, y: 0, width: 800, height: 600), configuration: config)
            view = web; web.load(URLRequest(url: URL(string: "folio://app/index.html")!))
        }
        guard let view else { return nil }
        var ready = false
        for _ in 0..<100 {
            if (try? await view.evaluateJavaScript("typeof window.folio?.mergeGitCheckpoints === 'function'")) as? Bool == true { ready = true; break }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        guard ready else { throw GitFailure("The shared document could not be prepared. Omega will retry.") }
        var config: [String: Any] = ["mine": try JSONSerialization.jsonObject(with: JSONEncoder().encode(mine))]
        if let incoming { config["incoming"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(incoming)) }
        config["mineText"] = mineText; config["incomingText"] = incomingText; config["resolvedText"] = resolvedText
        let json = String(decoding: try JSONSerialization.data(withJSONObject: config), as: UTF8.self)
        guard let result = try await view.evaluateJavaScript("window.folio.mergeGitCheckpoints(\(json))") as? [String: Any] else { return nil }
        return try JSONDecoder().decode(LiveCheckpoint.self, from: JSONSerialization.data(withJSONObject: result))
    }
}

extension GitNotebooks {
    func start(notebook: Notebook) {
        self.notebook = notebook
        // Pending reviews also remain discoverable when automatic sync is off.
        Task {
            for entry in notebooks where !entry.autoSync {
                do {
                    let directory = try await Task.detached { try GitRunner().git(["rev-parse", "--absolute-git-dir"], at: entry.url).text.trimmingCharacters(in: .whitespacesAndNewlines) }.value
                    guard FileManager.default.fileExists(atPath: directory + "/omega-review.json"), !busy else { continue }
                    let session = try GitSyncSession(root: entry.url, restoring: true)
                    let files = try session.conflicts()
                    if !files.isEmpty { sessions[entry.path] = session; reviews[entry.path] = files; messages[entry.path] = "\(files.count) files need a look" }
                } catch { messages[entry.path] = error.localizedDescription }
            }
        }
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
    }
    func tick() {
        guard !busy, let notebook else { return }
        let candidates = notebooks.filter { $0.autoSync && sessions[$0.path] == nil && (nextSync[$0.path] ?? .distantPast) <= Date() }
        if let entry = candidates.min(by: { (nextSync[$0.path] ?? .distantPast) < (nextSync[$1.path] ?? .distantPast) }) { sync(entry, notebook: notebook) }
    }
    func automatic(_ entry: GitNotebook, enabled: Bool) {
        do {
            var updated = entry; updated.automatic = enabled
            try persist(notebooks.map { $0.path == entry.path ? updated : $0 })
            nextSync[entry.path] = .distantPast
        } catch { message = error.localizedDescription }
    }
    func flush(_ notebook: Notebook) async throws {
        if let editor = notebook.richEditor {
            let success = await withCheckedContinuation { continuation in editor.synchronize { continuation.resume(returning: $0) } }
            guard success else { throw GitChangedDuringSync() }
        }
        // Non-modal save: an outside edit is deferred for review, never overwritten.
        try notebook.prepareAssistantAccess()
    }
    func sync(_ entry: GitNotebook, notebook: Notebook) {
        guard !busy else { return }
        if sessions[entry.path] != nil { reviewing = entry.path; return }
        busy = true; syncingPath = entry.path; messages[entry.path] = "Syncing quietly…"
        Task {
            var session: GitSyncSession?
            do {
                try await flush(notebook)
                // Main actor prevents Markdown/checkpoint writes from interleaving with this snapshot.
                let prepared = try GitSyncSession(root: entry.url, restoring: true)
                session = prepared
                let restored = prepared.hasIncoming
                if !restored {
                    try await Task.detached {
                        let credentials = try GitRunner.helperArguments(provider: entry.provider, remote: GitRemote(prepared.record.remoteURL))
                        try prepared.fetch(credentials: credentials)
                    }.value
                    let pairs = try await Task.detached { try prepared.sharedPairs() }.value
                    for pair in pairs {
                        if let result = try await merger.merge(mine: pair.mine, incoming: pair.incoming, mineText: pair.mineText, incomingText: pair.incomingText) {
                            try await Task.detached {
                                try prepared.writeCandidate(pair.path, data: Data(result.text.utf8))
                                try prepared.writeCandidate(pair.checkpointPath, data: LiveCheckpointStore.encode(result))
                            }.value
                        } else { prepared.record.manual.append(pair.path) }
                    }
                }
                if prepared.hasIncoming, let selected = notebook.selected, selected.path.hasPrefix(entry.path + "/"),
                   let editor = notebook.richEditor, LiveCollaboration.shared.isSharing(editor) {
                    let path = String(selected.path.dropFirst(entry.path.count + 1))
                    if try prepared.candidate(path) == nil, !prepared.record.resolved.contains(path) { prepared.record.manual.append(path) }
                }
                let conflicts = try await Task.detached { try prepared.conflicts() }.value
                if !conflicts.isEmpty {
                    try prepared.saveReview(); sessions[entry.path] = prepared; reviews[entry.path] = conflicts
                    messages[entry.path] = "\(conflicts.count) " + (conflicts.count == 1 ? "file needs" : "files need") + " a look"
                    finish(entry); return
                }
                try await complete(prepared, entry: entry, notebook: notebook)
                session?.discard(); session = nil
            } catch {
                session?.discard()
                report(error, entry: entry)
            }
            finish(entry)
        }
    }
    func complete(_ session: GitSyncSession, entry: GitNotebook, notebook: Notebook) async throws {
        try await flush(notebook)
        var activePaths = Set<String>()
        if session.hasIncoming, let selected = notebook.selected, selected.path.hasPrefix(entry.path + "/"), let editor = notebook.richEditor, let web = editor.webView {
            let path = String(selected.path.dropFirst(entry.path.count + 1)), cpPath = session.checkpointPath(path)
            try session.validate(except: [path, cpPath])
            if let data = try session.candidate(path), let incoming = String(data: data, encoding: .utf8) {
                let baseData = try session.blob(session.record.head, path)
                let baseline = baseData.flatMap { String(data: $0, encoding: .utf8) }
                if data != baseData || LiveCollaboration.shared.isSharing(editor) {
                    var cp = try session.candidate(cpPath).flatMap { try? JSONDecoder().decode(LiveCheckpoint.self, from: $0) }
                    if let existing = cp, existing.text != incoming { cp = try await merger.merge(mine: existing, resolvedText: incoming) }
                    var config: [String: Any] = ["id": editor.identity, "expected": baseline ?? "", "text": incoming, "resolved": session.record.resolved.contains(path)]
                    if let cp { config["checkpoint"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(cp)) }
                    let json = String(decoding: try JSONSerialization.data(withJSONObject: config), as: UTF8.self)
                    let id = editor.identity
                    guard let result = try await web.evaluateJavaScript("window.folio.gitApply(\(json))") as? [String: Any],
                          notebook.selected == selected, editor.identity == id, let text = result["text"] as? String, notebook.text == text else { throw GitChangedDuringSync() }
                    // The JS transaction sends its checkpoint before replying. Saving now
                    // pairs its latest Markdown with that durable shared state.
                    try notebook.prepareAssistantAccess()
                    if let value = result["checkpoint"] as? [String: Any] {
                        let checkpoint = try JSONDecoder().decode(LiveCheckpoint.self, from: JSONSerialization.data(withJSONObject: value))
                        try LiveCheckpointStore.write(checkpoint, to: entry.url.appendingPathComponent(cpPath), root: entry.url)
                        activePaths.insert(cpPath)
                    }
                    activePaths.insert(path)
                } else if notebook.text != baseline { throw GitChangedDuringSync() }
            }
        }
        // No awaits in this brief checkout transaction. Edits arriving from WebKit
        // are handled afterwards and saved against the new disk baseline.
        notebook.gitSyncing = true
        do { try session.apply(activePaths: activePaths); notebook.gitSyncing = false }
        catch { notebook.gitSyncing = false; throw error }
        if let selected = notebook.selected, session.record.resolved.contains(String(selected.path.dropFirst(entry.path.count + 1))),
           !FileManager.default.fileExists(atPath: selected.path) { notebook.closeDeletedBySync(selected) }
        notebook.refreshFromDisk()
        reviews.removeValue(forKey: entry.path); sessions.removeValue(forKey: entry.path)
        messages[entry.path] = "Saving to repository…"
        let result = try await Task.detached {
            let credentials = try GitRunner.helperArguments(provider: entry.provider, remote: GitRemote(session.record.remoteURL))
            return try session.push(credentials: credentials)
        }.value
        messages[entry.path] = result; failures[entry.path] = 0; nextSync[entry.path] = Date().addingTimeInterval(30)
        reviews.removeValue(forKey: entry.path); sessions.removeValue(forKey: entry.path)
    }
    func finish(_ entry: GitNotebook) { busy = false; syncingPath = nil; if nextSync[entry.path] == nil { nextSync[entry.path] = Date().addingTimeInterval(30) } }
    func report(_ error: Error, entry: GitNotebook) {
        if error is GitChangedDuringSync {
            messages[entry.path] = "New edits saved · syncing again shortly"; nextSync[entry.path] = Date().addingTimeInterval(3)
        } else {
            let count = min(5, (failures[entry.path] ?? 0) + 1); failures[entry.path] = count
            messages[entry.path] = error.localizedDescription + (entry.autoSync ? " Retrying automatically." : "")
            nextSync[entry.path] = Date().addingTimeInterval(min(300, 15 * pow(2, Double(count - 1))))
        }
    }
    enum Resolution { case mine, incoming, both, edited(String) }
    func resolve(_ review: GitReview, in entry: GitNotebook, choice: Resolution, notebook: Notebook) {
        guard !busy, let session = sessions[entry.path] else { return }
        busy = true; message = ""
        Task {
            do {
                try await flush(notebook)
                // A decision is always about the exact copies shown to the user.
                // If either changed locally, rebuild the review before accepting it.
                try session.validate()
                var chosen: Data?
                switch choice { case .mine, .both: chosen = review.mine; case .incoming: chosen = review.incoming; case .edited(let value): chosen = Data(value.utf8) }
                if case .both = choice, let incoming = review.incoming, let workspace = session.workspace {
                    let original = URL(fileURLWithPath: review.path), stem = original.deletingPathExtension().lastPathComponent
                    // URL(fileURLWithPath:) makes relative paths absolute; use NSString for the directory.
                    let parent = (review.path as NSString).deletingLastPathComponent
                    var number = 1, path = ""
                    repeat {
                        let name = stem + " (incoming" + (number == 1 ? "" : " \(number)") + ")" + (original.pathExtension.isEmpty ? "" : "." + original.pathExtension)
                        path = parent.isEmpty ? name : parent + "/" + name; number += 1
                    } while FileManager.default.fileExists(atPath: workspace.appendingPathComponent(path).path) || FileManager.default.fileExists(atPath: entry.url.appendingPathComponent(path).path)
                    try session.writeCandidate(path, data: incoming)
                }
                if let cpPath = review.checkpointPath {
                    let mine = try session.blob(session.record.head, cpPath).flatMap { try? JSONDecoder().decode(LiveCheckpoint.self, from: $0) }
                    let incoming = try session.record.fetched.flatMap { try session.blob($0, cpPath) }.flatMap { try? JSONDecoder().decode(LiveCheckpoint.self, from: $0) }
                    if let selected = chosen.flatMap({ String(data: $0, encoding: .utf8) }), let checkpoint = mine ?? incoming {
                        guard let resolved = try await merger.merge(mine: checkpoint, incoming: mine == nil ? nil : incoming, resolvedText: selected) else { throw GitFailure("This change switches document formats. Keep both copies, then open the incoming copy separately.") }
                        chosen = Data(resolved.text.utf8)
                        try session.writeCandidate(cpPath, data: LiveCheckpointStore.encode(resolved))
                    } else { try session.writeCandidate(cpPath, data: nil) }
                }
                try session.writeCandidate(review.path, data: chosen)
                session.record.resolved.append(review.path)
                let remaining = try session.conflicts(); reviews[entry.path] = remaining
                try session.saveReview()
                if remaining.isEmpty {
                    try await complete(session, entry: entry, notebook: notebook)
                    session.discard(); sessions.removeValue(forKey: entry.path); reviewing = nil
                } else { messages[entry.path] = "\(remaining.count) files need a look" }
            } catch {
                if error is GitChangedDuringSync {
                    var draftNotice = ""
                    if case .edited(let draft) = choice {
                        let original = entry.url.appendingPathComponent(review.path)
                        let copy = NoteFiles.uniqueURL(in: original.deletingLastPathComponent(), name: original.deletingPathExtension().lastPathComponent + " (review draft)", ext: original.pathExtension)
                        do { try DraftRecovery.write(draft, to: copy); notebook.reloadTree(); draftNotice = " Your combined draft is saved as “\(copy.lastPathComponent)”." }
                        catch { message = "Your draft could not be saved. Copy it from this review before closing."; finish(entry); return }
                    }
                    session.discard(); sessions.removeValue(forKey: entry.path); reviews.removeValue(forKey: entry.path)
                    message = "This notebook changed while you were reviewing. Omega is preparing the latest copies; your notes are safe." + draftNotice
                } else { message = error.localizedDescription }
                if session.applied { session.discard(); sessions.removeValue(forKey: entry.path); reviews.removeValue(forKey: entry.path); reviewing = nil }
                report(error, entry: entry)
            }
            finish(entry)
        }
    }
}

struct GitSyncIndicator: View {
    @ObservedObject var notebook: Notebook
    @ObservedObject private var git = GitNotebooks.shared
    private var entry: GitNotebook? { git.notebooks.first { notebook.selected?.path.hasPrefix($0.path + "/") == true } }
    var body: some View {
        if let entry {
            let count = git.reviews[entry.path]?.count ?? 0
            Menu {
                Text(git.messages[entry.path] ?? (entry.autoSync ? "Syncs automatically every 30 seconds" : "Automatic sync is off"))
                if count > 0 { Button("Review \(count) conflicting " + (count == 1 ? "file" : "files")) { git.reviewing = entry.path } }
                Button("Sync now") { git.sync(entry, notebook: notebook) }.disabled(git.busy)
                Toggle("Automatic sync", isOn: Binding(get: { entry.autoSync }, set: { git.automatic(entry, enabled: $0) }))
                Button("Git settings") { notebook.settingsDestination = "Git sync"; notebook.showingSettings = true }
            } label: {
                HStack(spacing: 4) { Image(systemName: count > 0 ? "arrow.triangle.branch" : "arrow.triangle.2.circlepath"); if count > 0 { Text("Review \(count)") } }
                    .font(.system(size: 10 * min(CGFloat(notebook.zoom), 1.5)))
            }.menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                .help(count > 0 ? "Review sync conflicts" : (git.messages[entry.path] ?? "Git sync"))
                .accessibilityLabel(count > 0 ? "Review sync conflicts" : "Git sync status")
        }
    }
}

// A workspace, not a sheet. Keeping the ordinary editor mounted underneath also
// keeps its live connection, selection and undo stack intact while reviewing.
struct GitConflictView: View {
    @ObservedObject var notebook: Notebook
    @ObservedObject var git = GitNotebooks.shared
    let entry: GitNotebook
    @State private var selected = ""
    private var files: [GitReview] { git.reviews[entry.path] ?? [] }
    private var current: GitReview? { files.first { $0.path == selected } ?? files.first }
    private var muted: Color { Color(nsColor: Ink.muted) }
    var body: some View {
        GeometryReader { geometry in
            let narrow = geometry.size.width < 760
            HStack(spacing: 0) {
                if !narrow { navigation.frame(width: 222) }
                VStack(spacing: 0) {
                    HStack(spacing: 10) {
                        if narrow { back }
                        Text("Sync review").foregroundStyle(muted)
                        Text("/").foregroundStyle(muted.opacity(0.5))
                        Text(entry.url.lastPathComponent).lineLimit(1)
                        Spacer(minLength: 4)
                        if git.busy { ProgressView().controlSize(.small) }
                        Text("\(files.count) " + (files.count == 1 ? "file remaining" : "files remaining")).foregroundStyle(muted).font(.system(size: 11))
                    }.font(.system(size: 12)).padding(.horizontal, 20)
                        .padding(.top, narrow && !notebook.fullscreen ? 28 : 0)
                        .frame(minHeight: 44).background(WindowDragRegion())
                    Divider().opacity(0.45)
                    if narrow && !files.isEmpty {
                        Picker("Conflicting file", selection: Binding(get: { current?.path ?? "" }, set: { selected = $0 })) {
                            ForEach(files) { Text($0.path).tag($0.path) }
                        }.padding(.horizontal, 14).padding(.vertical, 8)
                    }
                    if !git.message.isEmpty {
                        Label(git.message, systemImage: "info.circle").font(.system(size: 12)).foregroundStyle(muted)
                            .fixedSize(horizontal: false, vertical: true).frame(maxWidth: .infinity, alignment: .leading).padding(14)
                    }
                    if let item = current {
                        GitMergeWebView(notebook: notebook, git: git, entry: entry, review: item)
                            .id(item.path + GitDigest.of((item.mine ?? Data()) + (item.incoming ?? Data())))
                    } else {
                        VStack(spacing: 12) {
                            Image(systemName: "checkmark.circle").font(.system(size: 30, weight: .light)).foregroundStyle(muted)
                            Text(git.busy ? "Finishing sync…" : "All changes reviewed").font(.system(size: 20, weight: .semibold))
                            Text(git.messages[entry.path] ?? "Your notes are safe on this Mac.").foregroundStyle(muted).font(.system(size: 12))
                            Button("Back to notes") { close() }.buttonStyle(.plain).padding(.top, 8)
                        }.frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }.frame(minWidth: 0, maxWidth: .infinity, maxHeight: .infinity).background(Color(nsColor: Ink.paper))
            }
        }.foregroundStyle(Color(nsColor: Ink.text)).ignoresSafeArea()
    }
    private var back: some View {
        Button { close() } label: { Label("Back", systemImage: "chevron.left").font(.system(size: 11)) }
            .buttonStyle(.plain).foregroundStyle(muted).help("Leave review · your draft is kept")
    }
    private var navigation: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack { back; Spacer() }.padding(.leading, notebook.fullscreen ? 16 : 78).frame(height: 44).background(WindowDragRegion())
            Text("Changes to review").font(.system(size: 16, weight: .semibold)).padding(.horizontal, 16).padding(.top, 24)
            Text(entry.url.lastPathComponent).font(.system(size: 11)).foregroundStyle(muted).padding(.horizontal, 16).padding(.top, 6).padding(.bottom, 22)
            ScrollView {
                VStack(spacing: 3) {
                    ForEach(files) { file in
                        Button { selected = file.path } label: {
                            HStack(alignment: .top, spacing: 9) {
                                Image(systemName: file.editable ? "doc.text" : "doc").font(.system(size: 12)).padding(.top, 2).foregroundStyle(muted)
                                VStack(alignment: .leading, spacing: 4) {
                                    Text((file.path as NSString).lastPathComponent).font(.system(size: 12, weight: .medium)).lineLimit(2)
                                    let folder = (file.path as NSString).deletingLastPathComponent
                                    if !folder.isEmpty { Text(folder).font(.system(size: 10)).foregroundStyle(muted).lineLimit(1).truncationMode(.middle) }
                                    Text(file.mine == nil || file.incoming == nil ? "Deleted on one side" : "Both changed").font(.system(size: 10)).foregroundStyle(muted)
                                }
                                Spacer(minLength: 0)
                                Circle().fill(Color(nsColor: NotebookTint.lavender.color).opacity(0.65)).frame(width: 5, height: 5).padding(.top, 5)
                            }.padding(10).frame(maxWidth: .infinity, alignment: .leading)
                                .background(current?.path == file.path ? Color.primary.opacity(0.055) : .clear, in: RoundedRectangle(cornerRadius: 6))
                        }.buttonStyle(.plain).disabled(git.busy)
                    }
                }.padding(.horizontal, 8)
            }
            VStack(alignment: .leading, spacing: 6) {
                Label("Originals preserved", systemImage: "clock.arrow.circlepath").font(.system(size: 11))
                Text("Both versions stay in local Git history while you review.").font(.system(size: 10)).foregroundStyle(muted).fixedSize(horizontal: false, vertical: true)
            }.padding(16)
        }.background(Color(nsColor: Ink.sidebar)).overlay(alignment: .trailing) { Rectangle().fill(Color(nsColor: Ink.separator)).frame(width: 1) }
    }
    private func close() { git.reviewing = nil; DispatchQueue.main.async { notebook.richEditor?.focus() } }
}

struct GitMergeWebView: NSViewRepresentable {
    @ObservedObject var notebook: Notebook
    @ObservedObject var git: GitNotebooks
    let entry: GitNotebook
    let review: GitReview
    @Environment(\.colorScheme) var colorScheme
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration(); config.websiteDataStore = .nonPersistent()
        config.userContentController.add(context.coordinator, name: "review")
        let view = WKWebView(frame: .zero, configuration: config); view.navigationDelegate = context.coordinator
        view.setValue(false, forKey: "drawsBackground")
        if let url = Bundle.main.url(forResource: "git-review", withExtension: "html") { view.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent()) }
        context.coordinator.web = view
        return view
    }
    func updateNSView(_ view: WKWebView, context: Context) {
        context.coordinator.parent = self
        if context.coordinator.ready { context.coordinator.appearance() }
    }
    static func dismantleNSView(_ view: WKWebView, coordinator: Coordinator) {
        coordinator.disposed = true; view.configuration.userContentController.removeScriptMessageHandler(forName: "review"); view.navigationDelegate = nil
    }
    @MainActor final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        var parent: GitMergeWebView
        weak var web: WKWebView?
        var ready = false, disposed = false
        init(_ parent: GitMergeWebView) { self.parent = parent }
        func webView(_ view: WKWebView, decidePolicyFor action: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            decisionHandler(action.navigationType == .other && action.request.url?.isFileURL == true ? .allow : .cancel)
        }
        func webView(_ view: WKWebView, didFinish navigation: WKNavigation!) {
            ready = true; appearance()
            let review = parent.review, draft = parent.git.sessions[parent.entry.path]?.record.reviewDrafts?[parent.review.path]
            Task {
                do {
                    var config: [String: Any] = ["path": review.path, "editable": review.editable, "currentDeleted": review.mine == nil, "incomingDeleted": review.incoming == nil,
                                               "currentSize": review.mine?.count ?? 0, "incomingSize": review.incoming?.count ?? 0]
                    if review.editable {
                        let document = try await Task.detached { try GitMergeDocument.make(review) }.value
                        config.merge(try JSONSerialization.jsonObject(with: JSONEncoder().encode(document)) as! [String: Any], uniquingKeysWith: { _, new in new })
                    }
                    config["branch"] = parent.git.sessions[parent.entry.path]?.record.remoteBranch
                    if let draft { config["draft"] = draft }
                    guard !disposed else { return }
                    _ = try await view.callAsyncJavaScript("window.omegaReview.open(config)", arguments: ["config": config], in: nil, contentWorld: .page)
                    appearance()
                } catch {
                    _ = try? await view.callAsyncJavaScript("window.omegaReview.error(message)", arguments: ["message": error.localizedDescription], in: nil, contentWorld: .page)
                }
            }
        }
        func appearance() {
            web?.evaluateJavaScript("window.omegaReview?.configure(\(parent.colorScheme == .dark), \(parent.git.busy))", completionHandler: nil)
        }
        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            guard !disposed, let value = message.body as? [String: Any], value["path"] as? String == parent.review.path,
                  let kind = value["kind"] as? String else { return }
            if kind == "draft", let draft = value["draft"] as? String, draft.utf8.count < 8_000_000, let session = parent.git.sessions[parent.entry.path] {
                if session.record.reviewDrafts == nil { session.record.reviewDrafts = [:] }
                session.record.reviewDrafts?[parent.review.path] = draft
                do { try session.saveReview() } catch { parent.git.message = "The review draft could not be saved. Keep this review open until it can be saved." }
            } else if kind == "resolve", !parent.git.busy, let choice = value["choice"] as? String {
                let resolution: GitNotebooks.Resolution
                switch choice {
                case "mine": resolution = .mine
                case "incoming": resolution = .incoming
                case "both": resolution = .both
                case "edited": guard parent.review.editable, let text = value["text"] as? String else { return }; resolution = .edited(text)
                default: return
                }
                parent.git.resolve(parent.review, in: parent.entry, choice: resolution, notebook: parent.notebook)
            }
        }
    }
}
