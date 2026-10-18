import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct AgentWorkflowSettings: View {
    @ObservedObject var notebook: Notebook
    let scale: CGFloat
    @State private var selectedRoot = ""
    @State private var message = ""
    @State private var error = false
    @State private var imported: BeadsImport.Preview?
    @State private var importName = "Beads tasks"
    @State private var importReview = false
    @State private var confirmingCoordinator = false
    private var root: URL? { notebook.roots.first { $0.path == selectedRoot } ?? notebook.roots.first }
    var body: some View {
        SettingsCard("Work with your agents", subtitle: "Omega keeps dependencies and handoffs. Your coding tools manage their own worktrees, execution and tests.", scale: scale) {
            Picker("Notebook", selection: $selectedRoot) { ForEach(notebook.roots, id: \.path) { Text($0.lastPathComponent).tag($0.path) } }
                .onAppear { if selectedRoot.isEmpty { selectedRoot = root?.path ?? "" } }
            HStack {
                Button("Set up a project…", action: setup).disabled(root == nil)
                Menu("Connect") {
                    Button("Copy Claude Code command") { copy(AgentSetup.command("Claude")) }
                    Button("Copy Codex command") { copy(AgentSetup.command("Codex")) }
                }
                Spacer()
                Button("Import Beads…", action: previewImport).disabled(root == nil)
            }
            Text("Project setup adds a managed section to AGENTS.md and CLAUDE.md, preserving and backing up existing instructions. Reconnect your assistant after an Omega update to discover new tools.")
                .font(.system(size: 10 * scale)).foregroundStyle(Color(nsColor: Ink.muted)).fixedSize(horizontal: false, vertical: true)
            Button("Install omega terminal command") { perform { let file = try AgentCLI.install(); message = "Installed " + file.path + ". Add ~/.local/bin to your shell PATH, then use omega ready." } }
            if !message.isEmpty { Text(message).font(.system(size: 11 * scale)).foregroundStyle(error ? Color.red : Color(nsColor: Ink.muted)).textSelection(.enabled) }
        } footer: {
            HStack {
                Text("Exclusive claims use one coordinating Mac.").foregroundStyle(Color(nsColor: Ink.muted))
                Spacer()
                Button("Use this Mac…") { confirmingCoordinator = true }.disabled(root == nil)
            }
        }
        .confirmationDialog("Use this Mac to coordinate task claims?", isPresented: $confirmingCoordinator, titleVisibility: .visible) {
            Button("Use this Mac") { perform { guard let root else { return }; try AgentSetup.designate(root); message = "This Mac coordinates claims for \(root.lastPathComponent). Connect every claiming agent to this Omega instance." } }
        } message: { Text("All claiming agents must connect to Omega on this Mac. Other Git replicas can edit plans, but cannot independently issue exclusive claims. Only designate one Mac for a shared notebook.") }
        .sheet(isPresented: $importReview) {
            VStack(alignment: .leading, spacing: 16) {
                Text("Import from Beads").font(.title2.weight(.semibold))
                Text("\(imported?.count ?? 0) issues → \(root?.lastPathComponent ?? "Notebook")").foregroundStyle(.secondary)
                TextField("New task page", text: $importName)
                Text("Creates a new task page with dependencies, hierarchy, owners and notes. The original Beads records are preserved in its metadata. Beads remains unchanged; this is a one-time import, not two-way sync.").font(.callout)
                if error { Text(message).font(.callout).foregroundStyle(.red).textSelection(.enabled) }
                if let imported, !imported.warnings.isEmpty { ScrollView { VStack(alignment: .leading, spacing: 6) { ForEach(Array(imported.warnings.enumerated()), id: \.offset) { Text($0.element).font(.caption) } } }.frame(maxHeight: 160) }
                HStack { Button("Cancel") { importReview = false }; Spacer(); Button("Import task page", action: saveImport).buttonStyle(.borderedProminent).disabled(importName.trimmingCharacters(in: .whitespaces).isEmpty) }
            }.padding(24).frame(width: 500)
        }
    }
    private func copy(_ text: String) { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text, forType: .string); message = "Connection command copied. Run it in your terminal, then reconnect your assistant."; error = false }
    private func perform(_ action: () throws -> Void) { do { try action(); error = false } catch { self.error = true; message = error.localizedDescription } }
    private func setup() {
        guard let root else { return }
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.allowsMultipleSelection = false; panel.prompt = "Set up project"; panel.message = "Choose the code project that should use tasks from \(root.lastPathComponent)."
        guard panel.runModal() == .OK, let project = panel.url else { return }
        perform { try AgentSetup.install(project: project, notebook: root); message = "Project instructions installed. Use Connect to copy the command for each assistant that is not already connected." }
    }
    private func previewImport() {
        let panel = NSOpenPanel(); panel.canChooseDirectories = false; panel.allowsMultipleSelection = false; panel.message = "Choose the JSONL file produced by bd export --no-memories. Beads itself will not be modified."; panel.allowedContentTypes = [.json, .plainText, .data]
        guard panel.runModal() == .OK, let file = panel.url else { return }
        perform { imported = try BeadsImport.preview(String(contentsOf: file, encoding: .utf8)); importReview = true }
    }
    private func saveImport() {
        guard let root, let imported else { return }
        let service = AssistantService(notebook)
        service.handle(["name": "create_note", "arguments": ["folder": root.path, "name": importName, "markdown": imported.markdown]]) { response in
            error = response["isError"] as? Bool == true
            if error { message = ((response["content"] as? [[String: Any]])?.first?["text"] as? String) ?? "Import failed." }
            else { message = "Imported \(imported.count) Beads issues. Review the new page before switching agents to Omega."; importReview = false }
        }
    }
}
