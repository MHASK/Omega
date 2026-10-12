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
    private var file: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Folio/Git/notebooks.json")
    }
    init() {
        if let data = try? Data(contentsOf: file), let items = try? JSONDecoder().decode([GitNotebook].self, from: data) { notebooks = items }
    }
    func remember(_ value: GitNotebook) throws {
        let next = notebooks.filter { $0.path != value.path } + [value]
        try persist(next)
    }
    func disconnect(_ value: GitNotebook) {
        do { try persist(notebooks.filter { $0 != value }) }
        catch { message = error.localizedDescription }
    }
    private func persist(_ next: [GitNotebook]) throws {
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
                    message = "Connected. Use Sync to share your notes and attachments."
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
                    message = "Ready. Notes stay local and sync when you choose."
                    notebook.loadFolder(destination)
                } catch { message = error.localizedDescription }
            case .failure(let error): message = error.localizedDescription
            }
        }
    }
    func sync(_ entry: GitNotebook, notebook: Notebook) {
        guard !busy else { return }
        notebook.afterSync {
            guard notebook.save() else { return }
            self.busy = true; notebook.gitSyncing = true; self.messages[entry.path] = "Syncing…"
            Task {
                let result = await Task.detached { Result {
                    let runner = GitRunner(), info = try runner.inspect(entry.url)
                    let credentials = try GitRunner.helperArguments(provider: entry.provider, remote: info.remote)
                    return try runner.sync(entry.url, credentials: credentials)
                } }.value
                self.busy = false; notebook.gitSyncing = false
                notebook.refreshFromDisk()
                switch result {
                case .success(let message): self.messages[entry.path] = message
                case .failure(let error): self.messages[entry.path] = error.localizedDescription
                }
            }
        }
    }
}

struct SettingsGitView: View {
    @ObservedObject var notebook: Notebook
    @ObservedObject private var git = GitNotebooks.shared
    @State private var provider: GitProvider = .github
    @State private var address = ""
    private var scale: CGFloat { CGFloat(notebook.zoom) }
    private var muted: Color { Color(nsColor: Ink.muted) }
    var body: some View {
        VStack(spacing: 18 * scale) {
            SettingsCard("Your existing accounts", subtitle: "Omega uses the GitHub or GitLab CLI on this Mac.", scale: scale) {
                ForEach(GitProvider.allCases) { item in
                    HStack {
                        Text(item.rawValue)
                        Spacer()
                        Text(git.accounts[item] ?? "Checking…").foregroundStyle(muted).lineLimit(1)
                    }.padding(.vertical, 3 * scale)
                }
            } footer: {
                HStack {
                    Text("No Omega account or separate token.")
                    Spacer()
                    Button("Refresh") { git.refreshAccounts() }.disabled(git.accountLoading).buttonStyle(.plain)
                }
            }
            SettingsCard("Git notebooks", subtitle: "Share Markdown notes, tasks, and attachments through your repository.", scale: scale) {
                if git.notebooks.isEmpty {
                    Text("Connect a Git folder or clone a repository to get started.").foregroundStyle(muted).fixedSize(horizontal: false, vertical: true)
                }
                ForEach(git.notebooks) { item in
                    VStack(alignment: .leading, spacing: 6 * scale) {
                        HStack(spacing: 10 * scale) {
                            VStack(alignment: .leading, spacing: 3 * scale) {
                                Text(item.url.lastPathComponent).fontWeight(.medium)
                                Text(item.provider.rawValue).font(.system(size: 10 * scale)).foregroundStyle(muted)
                            }
                            Spacer(minLength: 0)
                            Button("Sync") { git.sync(item, notebook: notebook) }.disabled(git.busy)
                            Menu {
                                Button("Open notebook") { notebook.loadFolder(item.url) }
                                Button("Show in Finder") { NSWorkspace.shared.open(item.url) }
                                Divider()
                                Button("Disconnect") { git.disconnect(item) }
                            } label: { OpusIcon(glyph: "\u{f141}", size: 11 * scale) }.menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().disabled(git.busy).accessibilityLabel("Options for " + item.url.lastPathComponent)
                        }
                        Text(git.messages[item.path] ?? item.path).font(.system(size: 10 * scale)).foregroundStyle(muted).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                    }.padding(.vertical, 6 * scale)
                }
                Divider().opacity(0.5)
                Picker("Provider", selection: $provider) { ForEach(GitProvider.allCases) { Text($0.rawValue).tag($0) } }.pickerStyle(.segmented).frame(maxWidth: 230 * scale)
                TextField("https://github.com/you/notes", text: $address).textFieldStyle(.roundedBorder).accessibilityLabel("Repository HTTPS URL")
                HStack(spacing: 12 * scale) {
                    Button("Clone repository…", action: clone).disabled(address.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || git.busy)
                    Button("Open Git folder…", action: openFolder).disabled(git.busy)
                }
                if !git.message.isEmpty { Text(git.message).font(.system(size: 11 * scale)).foregroundStyle(muted).fixedSize(horizontal: false, vertical: true) }
            } footer: {
                Text("Sync commits and pushes notes and attachments to the connected repository. App preferences stay on this Mac. Conflicting edits are preserved for resolution in Git.").fixedSize(horizontal: false, vertical: true)
            }
        }.onAppear { git.refreshAccounts() }
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
