import SwiftUI
import AppKit

@MainActor final class GitNotebooks: ObservableObject {
    static let shared = GitNotebooks()
    @Published private(set) var notebooks: [GitNotebook] = []
    @Published var accounts: [GitProvider: String] = [:]
    @Published var messages: [String: String] = [:]
    @Published var busy = false
    @Published var accountLoading = false
    @Published var message = ""
    @Published var reviews: [String: [GitReview]] = [:]
    @Published var reviewing: String?
    @Published var syncingPath: String?
    var sessions: [String: GitSyncSession] = [:]
    var nextSync: [String: Date] = [:]
    var failures: [String: Int] = [:]
    var timer: Timer?
    weak var notebook: Notebook?
    let merger = GitCheckpointMerger()
    private let storageFile: URL?
    private var file: URL {
        if let storageFile { return storageFile }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Folio/Git/notebooks.json")
    }
    init(file: URL? = nil) {
        storageFile = file
        if let data = try? Data(contentsOf: self.file), let items = try? JSONDecoder().decode([GitNotebook].self, from: data) { notebooks = items }
    }
    func remember(_ value: GitNotebook) throws {
        let next = notebooks.filter { $0.path != value.path } + [value]
        try persist(next)
    }
    func disconnect(_ value: GitNotebook) {
        do { sessions.removeValue(forKey: value.path)?.discard(); reviews.removeValue(forKey: value.path); try persist(notebooks.filter { $0 != value }); LiveCollaboration.shared.forget(folder: value.path) }
        catch { message = error.localizedDescription }
    }
    func persist(_ next: [GitNotebook]) throws {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try DraftRecovery.write(JSONEncoder().encode(next), to: file); notebooks = next
    }
    func refreshAccounts() {
        guard !accountLoading else { return }; accountLoading = true
        Task {
            let result = await Task.detached { () -> [GitProvider: String] in
                var values: [GitProvider: String] = [:]
                for provider in GitProvider.allCases {
                    values[provider] = (try? GitRunner().account(provider)) ?? (GitRunner.cli(provider.cli) == nil ? "CLI not installed" : "Not signed in")
                }
                return values
            }.value
            accounts = result; accountLoading = false
        }
    }
    func connect(_ root: URL, provider: GitProvider, notebook: Notebook) {
        guard !busy else { return }; busy = true; message = "Checking repository…"
        Task {
            let result = await Task.detached { Result { try GitRunner().inspect(root) } }.value
            busy = false
            switch result {
            case .success(let info):
                do {
                    try remember(GitNotebook(path: root.path, provider: provider))
                    messages[root.path] = info.remote.host + "/" + info.remote.project + " · " + info.branch
                    message = "Connected. Notes and attachments now sync automatically."
                    notebook.loadFolder(root)
                } catch { message = error.localizedDescription }
            case .failure(let error): message = error.localizedDescription
            }
        }
    }
    func clone(_ remote: GitRemote, provider: GitProvider, destination: URL, notebook: Notebook) {
        guard !busy else { return }; busy = true; message = "Cloning repository…"
        Task {
            let result = await Task.detached { Result { try GitRunner().clone(remote, provider: provider, to: destination) } }.value
            busy = false
            switch result {
            case .success:
                do {
                    try remember(GitNotebook(path: destination.path, provider: provider))
                    messages[destination.path] = remote.host + "/" + remote.project
                    message = "Ready. Notes stay local and sync automatically."
                    notebook.loadFolder(destination)
                } catch { message = error.localizedDescription }
            case .failure(let error): message = error.localizedDescription
            }
        }
    }

}

// Sharing is a view onto the repository's existing permissions, never a new ACL.
struct DocumentToolbar: View {
    @ObservedObject var notebook: Notebook
    @State private var sharing = false
    private var scale: CGFloat { min(CGFloat(notebook.zoom), 1.5) }
    var body: some View {
        HStack(spacing: 3 * scale) {
            if !notebook.text.hasPrefix(TaskDocument.marker) {
                if !notebook.documentIsSource {
                    Button { sharing = false; notebook.richEditor?.command("comments") } label: {
                        HStack(spacing: 4 * scale) {
                            Image(systemName: "bubble.right").font(.system(size: 12 * scale))
                            if notebook.documentComments > 0 { Text("\(notebook.documentComments)").font(.system(size: 9 * scale)).monospacedDigit() }
                        }.frame(minWidth: 24 * scale, minHeight: 24 * scale)
                    }.help("Comments").accessibilityLabel("Comments")
                }
                Button { sharing = false; notebook.richEditor?.command("appearance") } label: {
                    Text("Aa").font(.system(size: 12 * scale)).frame(width: 28 * scale, height: 24 * scale)
                }.help("Document appearance").accessibilityLabel("Document appearance")
            }
            Button { notebook.richEditor?.command("closeWriting"); sharing.toggle() } label: {
                HStack(spacing: 5 * scale) { Image(systemName: "square.and.arrow.up").font(.system(size: 11 * scale)); Text("Share").font(.system(size: 11 * scale)) }
                    .padding(.horizontal, 6 * scale).frame(height: 24 * scale)
            }.help("Share this note").accessibilityLabel("Share this note")
                .popover(isPresented: $sharing, arrowEdge: .bottom) { NoteSharingView(notebook: notebook) { sharing = false } }
        }.buttonStyle(DocumentToolbarButtonStyle()).foregroundStyle(Color(nsColor: Ink.muted))
        .onChange(of: notebook.selected) { _, _ in sharing = false }
    }
}

private struct DocumentToolbarButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View { ToolbarButton(configuration: configuration) }
    private struct ToolbarButton: View {
        let configuration: Configuration
        @State private var hovered = false
        var body: some View { configuration.label.contentShape(Rectangle()).background(Color.primary.opacity(configuration.isPressed ? 0.09 : hovered ? 0.05 : 0), in: RoundedRectangle(cornerRadius: 4)).onHover { hovered = $0 } }
    }
}

struct NoteSharingView: View {
    @ObservedObject var notebook: Notebook
    @ObservedObject private var git = GitNotebooks.shared
    @ObservedObject private var live = LiveCollaboration.shared
    var close: () -> Void
    @State private var info: GitSnapshot?
    @State private var published = false
    @State private var loading = true
    @State private var error = ""
    @State private var copied = false
    private var scale: CGFloat { min(CGFloat(notebook.zoom), 1.15) }
    private var muted: Color { Color(nsColor: Ink.muted) }
    private var entry: GitNotebook? { guard let note = notebook.selected else { return nil }; return git.notebooks.filter { note.path.hasPrefix($0.path + "/") }.max { $0.path.count < $1.path.count } }
    private var relative: String { guard let entry, let note = notebook.selected else { return "" }; return String(note.path.dropFirst(entry.path.count + 1)) }
    private var liveEnabled: Bool { live.configurations.contains { $0.folder == entry?.path && $0.enabled } }
    private var people: [String] { notebook.selected.map { live.people(at: $0) } ?? [] }
    private var fileLink: String? {
        guard let info, let entry, !relative.isEmpty else { return nil }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
        let branch = info.branch.addingPercentEncoding(withAllowedCharacters: allowed) ?? info.branch
        let path = relative.split(separator: "/").map { String($0).addingPercentEncoding(withAllowedCharacters: allowed) ?? String($0) }.joined(separator: "/")
        return "https://\(info.remote.host)/\(info.remote.project)/" + (entry.provider == .gitlab ? "-/blob/" : "blob/") + branch + "/" + path
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Share").font(.system(size: 12 * scale, weight: .semibold))
                Spacer()
                Button(action: close) { Image(systemName: "xmark").font(.system(size: 10 * scale)).frame(width: 22 * scale, height: 22 * scale) }.buttonStyle(.plain).foregroundStyle(muted).accessibilityLabel("Close sharing")
            }.padding(.bottom, 12 * scale)
            if entry == nil {
                HStack(spacing: 8 * scale) { Image(systemName: "lock").foregroundStyle(muted); Text("Only on this Mac").fontWeight(.medium) }
                Text("Connect a Git notebook to share notes with people who have access to its repository.").foregroundStyle(muted).fixedSize(horizontal: false, vertical: true).lineSpacing(3 * scale).padding(.top, 8 * scale)
                divider
                action("Set up sharing", icon: "arrow.up.right") { settings() }
            } else if loading {
                HStack(spacing: 8) { ProgressView().controlSize(.small); Text("Checking notebook…").foregroundStyle(muted) }.padding(.vertical, 12)
            } else if let info, let entry {
                HStack(alignment: .top, spacing: 9 * scale) {
                    Image(systemName: "point.3.connected.trianglepath.dotted").foregroundStyle(muted)
                    VStack(alignment: .leading, spacing: 4 * scale) {
                        Text(info.remote.project).fontWeight(.medium).textSelection(.enabled)
                        Text(info.branch + " · " + relative).font(.system(size: 10 * scale)).foregroundStyle(muted).lineLimit(2).truncationMode(.middle)
                    }
                }
                Text("Access is managed in \(entry.provider.rawValue) for the whole repository.").foregroundStyle(muted).fixedSize(horizontal: false, vertical: true).lineSpacing(3 * scale).padding(.top, 10 * scale)
                HStack {
                    action(copied ? "Copied" : "Copy note link", icon: copied ? "checkmark" : "link") {
                        guard let fileLink else { return }; NSPasteboard.general.clearContents(); NSPasteboard.general.setString(fileLink, forType: .string); copied = true
                    }.disabled(!published)
                    Spacer(minLength: 8)
                    Button("Repository ↗") { if let url = URL(string: "https://" + info.remote.host + "/" + info.remote.project) { NSWorkspace.shared.open(url) } }.buttonStyle(.plain).foregroundStyle(muted)
                }.padding(.top, 12 * scale)
                Text(published ? "Opens the last synced version. A link doesn’t grant access." : "Sync the notebook before sharing this new note’s link.").font(.system(size: 9 * scale)).foregroundStyle(muted).fixedSize(horizontal: false, vertical: true).padding(.top, 7 * scale)
                divider
                HStack {
                    Circle().fill(Color(nsColor: live.active ? NotebookTint.mint.color : Ink.muted)).frame(width: 5 * scale, height: 5 * scale)
                    Text("Live editing").fontWeight(.medium)
                    Spacer()
                    Button(liveEnabled ? "Pause" : "Enable") {
                        if let configuration = live.configurations.first(where: { $0.folder == entry.path }) {
                            if liveEnabled { live.leave(notebook: notebook) }
                            live.configure(entry, address: configuration.endpoint, enabled: configuration.enabled == false, notebook: notebook)
                        } else { settings() }
                    }.buttonStyle(.plain).foregroundStyle(muted)
                }
                Text(liveEnabled ? (live.active ? (people.isEmpty ? "Just you here. Others can join this note." : people.joined(separator: ", ") + " here with you.") : live.status) : "Edit together using the same repository, branch and relay.").foregroundStyle(muted).fixedSize(horizontal: false, vertical: true).lineSpacing(3 * scale).padding(.top, 7 * scale)
                divider
                HStack { Text(entry.autoSync ? "Saved locally. Git syncs automatically." : "Saved locally. Automatic sync is off.").font(.system(size: 9 * scale)).foregroundStyle(muted); Spacer(minLength: 6); Button("Manage") { settings() }.buttonStyle(.plain) }
            }
            if !error.isEmpty { Text(error).foregroundStyle(muted).fixedSize(horizontal: false, vertical: true).padding(.top, 8); Button("Open Git settings") { settings() }.buttonStyle(.plain).padding(.top, 12) }
        }.font(.system(size: 11 * scale)).padding(16 * scale).frame(width: 300 * scale).background(Color(nsColor: Ink.paper))
        .task(id: notebook.selected) {
            guard let entry else { loading = false; return }
            let path = relative
            do {
                let result = try await Task.detached {
                    let runner = GitRunner(timeout: 10), snapshot = try runner.inspect(entry.url)
                    let exists = try runner.git(["cat-file", "-e", "refs/remotes/origin/" + snapshot.branch + ":" + path], at: entry.url, allowFailure: true).status == 0
                    return (snapshot, exists)
                }.value
                guard !Task.isCancelled else { return }; info = result.0; published = result.1
            } catch { self.error = error.localizedDescription }
            loading = false
        }
    }
    private var divider: some View { Rectangle().fill(Color(nsColor: Ink.separator)).frame(height: 1).padding(.vertical, 14 * scale) }
    private func action(_ title: String, icon: String, perform: @escaping () -> Void) -> some View {
        Button(action: perform) { Label(title, systemImage: icon).font(.system(size: 10 * scale, weight: .medium)).padding(.horizontal, 10 * scale).padding(.vertical, 7 * scale).background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 5)) }.buttonStyle(.plain)
    }
    private func settings() { close(); notebook.settingsDestination = "Git sync"; notebook.showingSettings = true }
}

struct SettingsGitView: View {
    @ObservedObject var notebook: Notebook
    @ObservedObject private var git = GitNotebooks.shared
    @ObservedObject private var live = LiveCollaboration.shared
    @State private var provider: GitProvider = .github
    @State private var address = ""
    @State private var cloning = false
    @State private var selectedFolder = ""
    @State private var relay = "https://omega.naridon.com"
    private var scale: CGFloat { CGFloat(notebook.zoom) }
    private var muted: Color { Color(nsColor: Ink.muted) }
    private var selected: GitNotebook? { git.notebooks.first { $0.path == selectedFolder } ?? git.notebooks.first }
    var body: some View {
        VStack(alignment: .leading, spacing: 24 * scale) {
            VStack(alignment: .leading, spacing: 12 * scale) {
                HStack { caption("ACCOUNTS"); Spacer(); Button { git.refreshAccounts() } label: { OpusIcon(glyph: "\u{f021}", size: 11 * scale) }.buttonStyle(.plain).foregroundStyle(muted).disabled(git.accountLoading).help("Refresh accounts").accessibilityLabel("Refresh accounts") }
                VStack(spacing: 0) {
                    ForEach(GitProvider.allCases) { item in
                        HStack(spacing: 11 * scale) {
                            Image(systemName: "person.crop.circle").font(.system(size: 19 * scale, weight: .light)).foregroundStyle(muted).frame(width: 28 * scale)
                            Text(item.rawValue).fontWeight(.medium)
                            Spacer(minLength: 8)
                            Text(git.accounts[item] ?? "Checking…").foregroundStyle(muted).lineLimit(1)
                        }.font(.system(size: 11 * scale)).padding(.horizontal, 16 * scale).padding(.vertical, 13 * scale)
                        if item == .github { line.padding(.leading, 55 * scale) }
                    }
                }.background(surface, in: RoundedRectangle(cornerRadius: 8 * scale)).overlay(RoundedRectangle(cornerRadius: 8 * scale).stroke(border, lineWidth: 1))
                Text("Your existing CLI logins. No new account.").font(.system(size: 10 * scale)).foregroundStyle(muted)
            }
            VStack(alignment: .leading, spacing: 12 * scale) {
                HStack { caption("NOTEBOOKS"); Spacer(); Menu { Button("Open Git folder…", action: openFolder); Button("Clone repository…") { cloning = true } } label: { HStack(spacing: 5 * scale) { OpusIcon(glyph: "\u{f067}", size: 10 * scale); Text("Connect") } }.menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().disabled(git.busy).accessibilityLabel("Connect notebook") }
                VStack(spacing: 0) {
                    if git.notebooks.isEmpty {
                        VStack(spacing: 10 * scale) {
                            OpusIcon(glyph: "\u{f126}", size: 24 * scale).foregroundStyle(muted.opacity(0.65)).padding(.bottom, 3 * scale)
                            Text("A shared home for your notes").font(.system(size: 13 * scale, weight: .medium))
                            Text("Connect a repository to sync notes and tasks.").font(.system(size: 11 * scale)).foregroundStyle(muted)
                            HStack(spacing: 10 * scale) { action("Open a folder", primary: true, action: openFolder); action("Clone repository") { cloning = true } }.padding(.top, 7 * scale)
                        }.padding(26 * scale).frame(maxWidth: .infinity)
                    }
                    ForEach(git.notebooks) { item in
                        HStack(spacing: 12 * scale) {
                            OpusIcon(glyph: "\u{f02d}", size: 18 * scale).foregroundStyle(muted)
                            VStack(alignment: .leading, spacing: 4 * scale) {
                                Text(item.url.lastPathComponent).font(.system(size: 12 * scale, weight: .medium))
                                Text(git.messages[item.path] ?? item.provider.rawValue + " · " + item.path).font(.system(size: 10 * scale)).foregroundStyle(muted).lineLimit(2)
                            }
                            Spacer(minLength: 8)
                            if let conflicts = git.reviews[item.path], !conflicts.isEmpty {
                                action("Review changes", primary: true) { git.reviewing = item.path }.disabled(git.busy)
                            } else { action(git.syncingPath == item.path ? "Syncing…" : "Sync now") { git.sync(item, notebook: notebook) }.disabled(git.busy) }
                            Menu { Toggle("Automatic sync", isOn: Binding(get: { item.autoSync }, set: { git.automatic(item, enabled: $0) })); Divider(); Button("Open notebook") { notebook.loadFolder(item.url) }; Button("Show in Finder") { NSWorkspace.shared.open(item.url) }; Divider(); Button("Disconnect") { live.leave(notebook: notebook); git.disconnect(item) } } label: { OpusIcon(glyph: "\u{f141}", size: 12 * scale) }.menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().accessibilityLabel("Options for " + item.url.lastPathComponent)
                        }.padding(.horizontal, 16 * scale).padding(.top, 16 * scale).padding(.bottom, 10 * scale)
                        HStack {
                            Toggle("Sync automatically", isOn: Binding(get: { item.autoSync }, set: { git.automatic(item, enabled: $0) })).toggleStyle(.switch).controlSize(.mini)
                            Spacer()
                            Text("Every 30 seconds · live editing stays on").foregroundStyle(muted)
                        }.font(.system(size: 10 * scale)).padding(.horizontal, 16 * scale).padding(.bottom, 14 * scale)
                        if item.id != git.notebooks.last?.id { line.padding(.leading, 46 * scale) }
                    }
                }.background(surface, in: RoundedRectangle(cornerRadius: 8 * scale)).overlay(RoundedRectangle(cornerRadius: 8 * scale).stroke(border, lineWidth: 1))
                if !git.message.isEmpty { Text(git.message).font(.system(size: 10 * scale)).foregroundStyle(muted).fixedSize(horizontal: false, vertical: true) }
            }
            VStack(alignment: .leading, spacing: 12 * scale) {
                caption("LIVE EDITING")
                VStack(alignment: .leading, spacing: 16 * scale) {
                    HStack(alignment: .top, spacing: 12 * scale) {
                        OpusIcon(glyph: "\u{f0c0}", size: 18 * scale).foregroundStyle(muted).padding(.top, 2 * scale)
                        VStack(alignment: .leading, spacing: 5 * scale) { Text("Write together").font(.system(size: 13 * scale, weight: .medium)); Text("Live together. Saved on your Mac and in Git.").font(.system(size: 11 * scale)).foregroundStyle(muted).fixedSize(horizontal: false, vertical: true) }
                    }
                    if let item = selected {
                        if git.notebooks.count > 1 { Picker("Notebook", selection: $selectedFolder) { ForEach(git.notebooks) { Text($0.url.lastPathComponent).tag($0.path) } }.pickerStyle(.menu) }
                        VStack(alignment: .leading, spacing: 6 * scale) { Text("Relay address").font(.system(size: 10 * scale)).foregroundStyle(muted); TextField("https://relay.example.com", text: $relay).textFieldStyle(.plain).font(.system(size: 11 * scale)).padding(10 * scale).background(Color(nsColor: Ink.paper), in: RoundedRectangle(cornerRadius: 5 * scale)).overlay(RoundedRectangle(cornerRadius: 5 * scale).stroke(border, lineWidth: 1)).accessibilityLabel("Live relay address") }
                        HStack { Text(live.status).font(.system(size: 10 * scale)).foregroundStyle(muted).fixedSize(horizontal: false, vertical: true); Spacer(minLength: 12); if live.configurations.contains(where: { $0.folder == item.path && $0.enabled }) { action("Pause") { live.leave(notebook: notebook); live.configure(item, address: relay, enabled: false, notebook: notebook) } } else { action("Enable", primary: true) { live.configure(item, address: relay, enabled: true, notebook: notebook) } } }
                    } else { Text("Connect a Git notebook above to get started.").font(.system(size: 11 * scale)).foregroundStyle(muted) }
                    line
                    Text("Use a relay you trust. It receives your CLI credential briefly to verify repository write access, then discards it. The relay keeps no files or history. Live edits exist only in memory while someone is connected. Git sync saves notes and shared editing state to your repository.").font(.system(size: 10 * scale)).foregroundStyle(muted).fixedSize(horizontal: false, vertical: true).lineSpacing(2 * scale)
                    Button("Recovery copies") { live.revealBackups() }.buttonStyle(.plain).font(.system(size: 10 * scale)).foregroundStyle(muted)
                }.padding(18 * scale).background(surface, in: RoundedRectangle(cornerRadius: 8 * scale)).overlay(RoundedRectangle(cornerRadius: 8 * scale).stroke(border, lineWidth: 1))
            }
        }.onAppear { git.refreshAccounts(); selectedFolder = git.notebooks.first(where: { notebook.selected?.path.hasPrefix($0.path + "/") == true })?.path ?? selected?.path ?? ""; relay = live.configurations.first(where: { $0.folder == selectedFolder })?.endpoint ?? "https://omega.naridon.com" }
        .onChange(of: selectedFolder) { _, value in relay = live.configurations.first(where: { $0.folder == value })?.endpoint ?? "https://omega.naridon.com" }
        .sheet(isPresented: $cloning) { cloneSheet }
    }
    private var surface: Color { Color(nsColor: Ink.sidebar).opacity(0.25) }
    private var border: Color { Color(nsColor: Ink.separator).opacity(0.75) }
    private var line: some View { Rectangle().fill(border).frame(height: 1) }
    private func caption(_ text: String) -> some View { Text(text).font(.system(size: 9 * scale, weight: .medium)).tracking(1.1).foregroundStyle(muted) }
    private func action(_ title: String, primary: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) { Text(title).font(.system(size: 11 * scale, weight: .medium)).padding(.horizontal, 12 * scale).padding(.vertical, 7 * scale).background(primary ? Color(nsColor: NotebookTint.lavender.color).opacity(0.16) : Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 5 * scale)) }.buttonStyle(.plain)
    }
    private var cloneSheet: some View {
        VStack(alignment: .leading, spacing: 16 * scale) {
            Text("Connect a repository").font(.system(size: 18 * scale, weight: .semibold))
            Text("Choose where its notes will live on this Mac.").font(.system(size: 11 * scale)).foregroundStyle(muted)
            Picker("Provider", selection: $provider) { ForEach(GitProvider.allCases) { Text($0.rawValue).tag($0) } }.pickerStyle(.segmented).labelsHidden().frame(width: 200 * scale)
            TextField("", text: $address, prompt: Text(verbatim: provider == .github ? "https://github.com/you/notes" : "https://gitlab.com/you/notes")).textFieldStyle(.plain).padding(12 * scale).background(surface, in: RoundedRectangle(cornerRadius: 6 * scale)).overlay(RoundedRectangle(cornerRadius: 6 * scale).stroke(border, lineWidth: 1)).accessibilityLabel("Repository HTTPS URL")
            HStack { Spacer(); action("Cancel") { cloning = false }; action("Choose folder…", primary: true) { cloning = false; clone() }.disabled(address.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) }
        }.padding(24 * scale).frame(width: 350 * scale).background(Color(nsColor: Ink.paper))
    }
    private func openFolder() {
        let panel = NSOpenPanel(); panel.title = "Open Git notebook"; panel.prompt = "Connect"
        panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url { git.connect(url, provider: provider, notebook: notebook) }
    }
    private func clone() {
        do {
            let remote = try GitRemote(address.trimmingCharacters(in: .whitespacesAndNewlines))
            let panel = NSSavePanel(); panel.title = "Choose where to keep this Git notebook"; panel.prompt = "Clone"
            panel.nameFieldStringValue = remote.project.split(separator: "/").last.map(String.init) ?? "Notes"
            panel.canCreateDirectories = true; panel.isExtensionHidden = false
            if panel.runModal() == .OK, let destination = panel.url { git.clone(remote, provider: provider, destination: destination, notebook: notebook) }
        } catch { git.message = error.localizedDescription }
    }
}
