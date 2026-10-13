import AppKit
import SwiftUI
import Combine
import CryptoKit

struct LiveConfiguration: Codable, Equatable {
    var folder: String
    var endpoint: String
    var enabled: Bool
}

@MainActor final class LiveCollaboration: NSObject, ObservableObject {
    static let shared = LiveCollaboration()
    @Published var configurations: [LiveConfiguration] = []
    @Published var status = "Not connected"
    @Published var peers: [String] = []
    @Published private(set) var filePeople: [URL: [String]] = [:]
    @Published var active = false
    @Published var connecting = false
    private weak var bridge: EditorBridge?
    private var identity = ""
    private var generation = UUID()
    private var socket: URLSessionWebSocketTask?
    private var retry: Task<Void, Never>?
    private var context: (GitNotebook, GitSnapshot, String, URL)?
    private var checkpoint: LiveCheckpoint?
    private var ready = false
    private var sequence = 0
    private var stoppedForError = false
    private let directory: URL
    private var configFile: URL { directory.appendingPathComponent("connections.json") }
    override init() {
        directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Folio/Collaboration", isDirectory: true)
        super.init()
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        if let data = try? Data(contentsOf: configFile), let saved = try? JSONDecoder().decode([LiveConfiguration].self, from: data) { configurations = saved }
    }
    static func endpoint(_ text: String) throws -> URL {
        guard let url = URL(string: text), let c = URLComponents(url: url, resolvingAgainstBaseURL: false), c.scheme == "https", c.host != nil, c.user == nil, c.password == nil, c.query == nil, c.fragment == nil, c.port == nil, c.path.isEmpty || c.path == "/" else { throw GitFailure("Enter a secure relay address, such as https://omega.naridon.com.") }
        return url
    }
    func configure(_ item: GitNotebook, address: String, enabled: Bool, notebook: Notebook) {
        do {
            _ = try Self.endpoint(address)
            configurations.removeAll { $0.folder == item.path }
            configurations.append(LiveConfiguration(folder: item.path, endpoint: address, enabled: enabled))
            try saveConfigurations()
            stop()
            if enabled {
                status = "Open a note in this notebook to join."
                notebook.showingSettings = false
                if let bridge = notebook.richEditor { prepare(bridge) }
            }
        } catch { status = error.localizedDescription }
    }
    private func saveConfigurations() throws { try DraftRecovery.write(String(decoding: JSONEncoder().encode(configurations), as: UTF8.self), to: configFile) }
    func leave(notebook: Notebook) {
        if let folder = context?.0.path, let index = configurations.firstIndex(where: { $0.folder == folder }) { configurations[index].enabled = false; try? saveConfigurations() }
        bridge?.webView?.evaluateJavaScript("window.folio.liveStop()")
        stop(); status = "Live editing paused"
    }
    func forget(folder: String) {
        configurations.removeAll { $0.folder == folder }; try? saveConfigurations()
        if context?.0.path == folder { bridge?.webView?.evaluateJavaScript("window.folio.liveStop()"); stop() }
    }
    func isSharing(_ editor: EditorBridge?) -> Bool { bridge === editor && !identity.isEmpty && checkpoint != nil }
    var hasSession: Bool { checkpoint != nil }
    func people(at url: URL) -> [String] { filePeople[url.standardizedFileURL] ?? [] }
    func revealBackups() { NSWorkspace.shared.open(directory) }
    func stop() {
        bridge?.webView?.evaluateJavaScript("window.folio.liveMessage({type:'offline'})", completionHandler: nil)
        generation = UUID(); retry?.cancel(); retry = nil; socket?.cancel(with: .goingAway, reason: nil); socket = nil
        ready = false; active = false; connecting = false; peers = []; filePeople = [:]; identity = ""; context = nil; checkpoint = nil; bridge = nil; stoppedForError = false
    }
    func prepare(_ editor: EditorBridge) {
        guard let notebook = editor.notebook, !notebook.gitSyncing, let selected = notebook.selected,
              let item = GitNotebooks.shared.notebooks.first(where: { selected.path.hasPrefix($0.path + "/") }),
              let config = configurations.first(where: { $0.folder == item.path && $0.enabled }),
              identity != editor.identity else { return }
        stop(); bridge = editor; identity = editor.identity; connecting = true; status = "Connecting…"
        let ticket = generation
        Task {
            do {
                let info = try await Task.detached { try GitRunner(timeout: 10).inspect(item.url) }.value
                guard ticket == generation, notebook.selected == selected else { return }
                guard info.remote.host == item.provider.defaultHost else { throw GitFailure("Live editing currently supports github.com and gitlab.com repositories.") }
                _ = try Self.endpoint(config.endpoint)
                let relative = String(selected.path.dropFirst(item.path.count + 1))
                let file = try LiveCheckpointStore.file(root: item.url, note: relative)
                let ignored = try GitRunner(timeout: 10).git(["check-ignore", "--no-index", "--quiet", "--", file.path], at: item.url, allowFailure: true)
                guard ignored.status == 1 else { throw GitFailure("Allow .omega/live in this repository’s Git ignore rules before enabling live editing. Shared history needs to travel with your notes.") }
                context = (item, info, relative, file)
                var payload: [String: Any] = ["id": identity]
                if let cached = try LiveCheckpointStore.read(file) {
                    if cached.text != notebook.text { payload["externalText"] = notebook.text }
                    payload["state"] = cached.state; payload["accepted"] = cached.accepted; checkpoint = cached
                }
                let started = try await editor.webView?.evaluateJavaScript("window.folio.liveStart(\(String(decoding: AssistantWire.json(payload), as: UTF8.self)))")
                if started as? Bool != true { throw GitFailure("Couldn’t start live editing") }
            } catch { if ticket == generation { status = error.localizedDescription; connecting = false } }
        }
    }
    func handle(_ body: [String: Any], editor: EditorBridge) {
        guard bridge === editor, body["id"] as? String == identity, identity == editor.identity else { return }
        switch body["type"] as? String {
        case "liveReady":
            guard let state = body["state"] as? String, let context else { return }
            do {
                let next = LiveCheckpoint(state: state, text: body["text"] as? String ?? editor.notebook?.text ?? "", accepted: body["accepted"] as? Bool ?? false)
                try LiveCheckpointStore.write(next, to: context.3, root: context.0.url)
                checkpoint = next; connect()
            } catch { stoppedForError = true; connecting = false; status = "Live editing paused: couldn’t save its Git checkpoint." }
        case "liveAwareness":
            guard ready, let socket, let update = body["update"] as? String, update.utf8.count <= 8192, let lineage = body["lineage"] as? String else { return }
            let message: [String: Any] = ["type": "awareness", "update": update, "lineage": lineage]
            socket.send(.string(String(decoding: AssistantWire.json(message), as: UTF8.self))) { _ in }
        case "liveCheckpoint":
            guard let state = body["state"] as? String, let text = body["text"] as? String, let context else { return }
            do {
                // Save Markdown's crash checkpoint and CRDT state before sending
                // anything over the network. A relay failure never owns the only copy.
                editor.notebook?.edit(text)
                let next = LiveCheckpoint(state: state, text: text, accepted: body["accepted"] as? Bool ?? false)
                try LiveCheckpointStore.write(next, to: context.3, root: context.0.url)
                checkpoint = next
                if ready && body["push"] as? Bool == true { push(update: body["update"] as? String, lineage: body["lineage"] as? String) }
            } catch { stoppedForError = true; socket?.cancel(); ready = false; active = false; status = "Live editing paused: couldn’t save its local recovery copy." }
        case "liveConflict":
            guard let notebook = editor.notebook, let selected = notebook.selected else { return }
            let alert = NSAlert(); alert.messageText = "This shared note has a different version"
            alert.informativeText = "Join the shared version, keeping a recovery copy of your local note, or keep editing locally. No version will be discarded."
            alert.addButton(withTitle: "Keep Local"); alert.addButton(withTitle: "Keep Copy & Join")
            if alert.runModal() == .alertSecondButtonReturn {
                do {
                    let backup = directory.appendingPathComponent("Local-" + UUID().uuidString + "-" + selected.lastPathComponent)
                    try DraftRecovery.write(notebook.text, to: backup)
                    editor.webView?.evaluateJavaScript("window.folio.liveAccept()")
                } catch { leave(notebook: notebook); notebook.showError(error) }
            } else { leave(notebook: notebook) }
        default: break
        }
    }
    private func connect() {
        guard !stoppedForError, let context, let config = configurations.first(where: { $0.folder == context.0.path && $0.enabled }), let seed = checkpoint?.state else { return }
        let ticket = generation; connecting = true; ready = false
        Task {
            do {
                let provider = context.0.provider
                let token = try await Task.detached {
                    guard let cli = GitRunner.cli(provider.cli) else { throw GitFailure("Sign in with \(provider.cli) first.") }
                    let result = try GitRunner(executable: cli, timeout: 15).run(["auth", "git-credential", "get"], in: FileManager.default.temporaryDirectory, input: "protocol=https\nhost=" + provider.defaultHost + "\n\n")
                    let token = result.text.components(separatedBy: "\n").first(where: { $0.hasPrefix("password=") }).map { String($0.dropFirst(9)) } ?? ""
                    guard !token.isEmpty, token.count < 4096, !token.contains("\n") else { throw GitFailure("Couldn’t read the existing CLI login.") }
                    return token
                }.value
                guard ticket == generation else { return }
                var components = URLComponents(url: try Self.endpoint(config.endpoint), resolvingAgainstBaseURL: false)!
                components.scheme = "wss"; components.path = "/live"
                let session = URLSession(configuration: .ephemeral)
                let ws = session.webSocketTask(with: components.url!); ws.maximumMessageSize = 6 * 1024 * 1024; socket = ws; ws.resume()
                let join: [String: Any] = ["type":"join", "protocol":1, "provider":provider == .github ? "github" : "gitlab", "project":context.1.remote.project, "branch":context.1.branch, "path":context.2, "token":token, "seed":seed]
                try await ws.send(.string(String(decoding: AssistantWire.json(join), as: UTF8.self)))
                defer { session.invalidateAndCancel() }
                while ticket == generation {
                    let incoming = try await ws.receive()
                    let data: Data
                    switch incoming { case .string(let text): data = Data(text.utf8); case .data(let bytes): data = bytes; @unknown default: continue }
                    guard let message = try JSONSerialization.jsonObject(with: data) as? [String: Any], let type = message["type"] as? String else { throw GitFailure("Invalid relay reply") }
                    if type == "error" { stoppedForError = true; throw GitFailure(message["message"] as? String ?? "The relay rejected this connection.") }
                    if type == "peers" { peers = message["users"] as? [String] ?? []; continue }
                    if type == "notebookPresence" {
                        var next: [URL: [String]] = [:]
                        let me = message["self"] as? String ?? ""
                        for file in (message["files"] as? [[String: Any]] ?? []).prefix(100) {
                            guard let path = file["path"] as? String, path.count <= 1000,
                                  !path.split(separator: "/", omittingEmptySubsequences: false).contains(where: { $0.isEmpty || $0.hasPrefix(".") || $0.contains("\\") }),
                                  let users = file["users"] as? [String] else { continue }
                            let url = context.0.url.appendingPathComponent(path).standardizedFileURL
                            guard url.path.hasPrefix(context.0.path + "/") else { continue }
                            next[url] = Array(Set(users.filter { $0 != me && !$0.isEmpty }.map { String($0.prefix(80)) })).sorted()
                        }
                        filePeople = next; continue
                    }
                    if type == "ack" { if message["sequence"] as? Int == sequence { status = "Live · synced" }; continue }
                    if type == "state" { ready = true; active = true; connecting = false; status = "Live" }
                    if type == "state" || type == "update" || type == "awareness" {
                        _ = try await bridge?.webView?.evaluateJavaScript("window.folio.liveMessage(\(String(decoding: AssistantWire.json(message), as: UTF8.self)))")
                    }
                }
            } catch {
                guard ticket == generation else { return }
                ready = false; active = false; connecting = false; peers = []; filePeople = [:]
                bridge?.webView?.evaluateJavaScript("window.folio.liveMessage({type:'offline'})", completionHandler: nil)
                status = stoppedForError ? error.localizedDescription : "Offline · saved on this Mac"
                if !stoppedForError {
                    retry = Task { try? await Task.sleep(nanoseconds: 4_000_000_000); if !Task.isCancelled && ticket == generation { connect() } }
                }
            }
        }
    }
    private func push(update: String? = nil, lineage: String?) {
        guard let socket, let state = update ?? checkpoint?.state, let lineage, ready else { return }
        sequence += 1; let message: [String: Any] = ["type":"update", "update":state, "sequence":sequence, "lineage":lineage]
        status = "Live · syncing"
        // WebSocket sends are ordered; snapshots merge idempotently in Yjs.
        socket.send(.string(String(decoding: AssistantWire.json(message), as: UTF8.self))) { _ in }
    }
}

struct FilePresenceView: View {
    let url: URL
    let scale: CGFloat
    @ObservedObject private var live = LiveCollaboration.shared
    var body: some View {
        let people = live.people(at: url)
        if !people.isEmpty {
            HStack(spacing: -3 * scale) {
                ForEach(Array(people.prefix(2)), id: \.self) { name in
                    Text(String(name.prefix(1)).uppercased()).font(.system(size: 8 * scale, weight: .medium))
                        .frame(width: 18 * scale, height: 18 * scale)
                        .background(Color(nsColor: NotebookTint.lavender.color).opacity(0.18), in: Circle())
                        .overlay(Circle().stroke(Color(nsColor: Ink.sidebar), lineWidth: 1.5))
                }
                if people.count > 2 { Text("+\(people.count - 2)").font(.system(size: 8 * scale)).padding(.leading, 5 * scale) }
            }.foregroundStyle(Color(nsColor: Ink.sidebarText).opacity(0.8)).padding(.horizontal, 5 * scale)
                .help(people.joined(separator: ", ") + " · here now")
                .accessibilityElement(children: .ignore).accessibilityLabel(people.joined(separator: ", ") + " editing this note")
        }
    }
}

struct LiveStatusView: View {
    @ObservedObject private var live = LiveCollaboration.shared
    @ObservedObject var notebook: Notebook
    var body: some View {
        if live.active || live.connecting || live.status.hasPrefix("Offline") {
            Menu {
                Text(live.status)
                ForEach(live.peers, id: \.self) { Text($0) }
                Button("Pause live editing") { live.leave(notebook: notebook) }
            } label: { HStack(spacing: 5) { Circle().fill(live.active ? Color(nsColor: NotebookTint.mint.color) : Color.secondary).frame(width: 5, height: 5); Text(live.active ? "Live" : live.connecting ? "Joining" : "Offline") } }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().help(live.status)
        }
    }
}
