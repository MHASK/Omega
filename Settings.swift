import SwiftUI
import AppKit

private struct StatusDraft: Identifiable {
    let id = UUID()
    var original: String?
    var name: String
}
private enum SettingsSection: String, CaseIterable, Identifiable {
    case appearance = "Appearance", tasks = "Tasks & goals", labels = "Labels", storage = "Notes & storage", assistants = "Assistants", git = "Git sync", about = "About Omega"
    var id: String { rawValue }
    var glyph: String {
        switch self { case .appearance: return "\u{f042}"; case .tasks: return "\u{f0ae}"; case .labels: return "\u{f02b}"; case .storage: return "\u{f07b}"; case .assistants: return "\u{f0c1}"; case .git: return "\u{f126}"; case .about: return "\u{f05a}" }
    }
    var subtitle: String {
        switch self {
        case .appearance: return "A comfortable place to think."
        case .tasks: return "A little structure for the work ahead."
        case .labels: return "A shared set of labels, quietly organized."
        case .storage: return "Your words stay in your own folders."
        case .assistants: return "Work alongside your local tools."
        case .git: return "Your notes, with a shared history."
        case .about: return "A quiet place for your words."
        }
    }
}

struct FolioSettingsView: View {
    @ObservedObject var notebook: Notebook
    @State private var section: SettingsSection = .appearance
    @AppStorage("assistantAccess") private var assistantEnabled = false
    @State private var copied = false
    @State private var scope = "defaults"
    @State private var rows: [StatusDraft] = []
    @State private var completedID: UUID?
    @State private var completedAlsoIDs: Set<UUID> = []
    @State private var pageURL: URL?
    @State private var pagePreferences: TaskPreferences?
    @State private var baseline = TaskPreferences()
    @State private var message = ""
    @State private var hasError = false
    @State private var saving = false
    @State private var pendingScope: String?
    @State private var confirmingDiscard = false
    @State private var closeAfterDiscard = false
    var scale: CGFloat { CGFloat(notebook.zoom) }
    private var muted: Color { Color(nsColor: Ink.muted) }
    private var accent: Color { Color(nsColor: NotebookTint.lavender.color) }
    private var additionalCompleted: [String] { rows.filter { completedAlsoIDs.contains($0.id) && $0.id != completedID }.map(\.name) }
    private var changes: Bool { additionalCompleted != (baseline.completedAlso ?? []) || rows.map(\.name) != baseline.statuses || rows.first(where: { $0.id == completedID })?.name != baseline.completed }

    var body: some View {
        GeometryReader { geometry in
            let compact = geometry.size.width < 650 * scale
            let sideWidth: CGFloat = compact ? min(64 * scale, 86) : 210 * scale
            HStack(spacing: 0) {
                if geometry.size.width >= 520 { navigation(compact: compact).frame(width: sideWidth) }
                VStack(spacing: 0) {
                    HStack {
                        if geometry.size.width < 520 {
                            Picker("Settings section", selection: $section) { ForEach(SettingsSection.allCases) { Text($0.rawValue).tag($0) } }.labelsHidden().frame(maxWidth: .infinity, alignment: .leading)
                        } else {
                        Text("Settings").foregroundStyle(muted)
                        Text("/").foregroundStyle(muted.opacity(0.5))
                        Text(section.rawValue).lineLimit(1)
                        }
                        Spacer(minLength: 4)
                        Button(notebook.gitSyncing ? "Syncing…" : "Done") { leave() }.buttonStyle(.plain).foregroundStyle(muted).accessibilityLabel("Close settings")
                    }
                    .font(.system(size: 11 * scale)).padding(.horizontal, compact ? 14 : 24 * scale)
                    .padding(.top, geometry.size.width < 520 && !notebook.fullscreen ? 30 : 0)
                    .frame(minHeight: min(40 * scale, 56)).background(WindowDragRegion())
                    .overlay(alignment: .bottom) { Rectangle().fill(Color(nsColor: Ink.separator)).frame(height: 1) }
                    ScrollView {
                        VStack(alignment: .leading, spacing: 18 * scale) {
                            VStack(alignment: .leading, spacing: 7 * scale) {
                                Text(section.rawValue).font(.system(size: 23 * scale, weight: .semibold)).tracking(-0.5)
                                Text(section.subtitle).font(.system(size: 12 * scale)).foregroundStyle(muted)
                            }.padding(.bottom, 5 * scale)
                            content
                        }
                        .frame(maxWidth: 590 * scale, alignment: .leading)
                        .padding(.horizontal, compact ? 14 : 32 * scale).padding(.top, 26 * scale).padding(.bottom, 48 * scale)
                        .frame(maxWidth: .infinity, alignment: .top)
                    }.scrollIndicators(.automatic).id(section)
                }.frame(minWidth: 0, maxWidth: .infinity, maxHeight: .infinity).background(Color(nsColor: Ink.paper))
            }
        }
        .font(.system(size: 12 * scale)).foregroundStyle(Color(nsColor: Ink.text)).tint(accent)
        .frame(maxWidth: .infinity, maxHeight: .infinity).ignoresSafeArea()
        .disabled(notebook.gitSyncing)
        .onReceive(NotificationCenter.default.publisher(for: .init("OmegaShowUpdateSettings"))) { _ in section = .about }
        .onExitCommand { leave() }
        .alert("Discard status changes?", isPresented: $confirmingDiscard) {
            Button("Keep editing", role: .cancel) { pendingScope = nil; closeAfterDiscard = false }
            Button("Discard changes", role: .destructive) {
                if let pendingScope { scope = pendingScope; self.pendingScope = nil; loadRows() }
                if closeAfterDiscard { closeAfterDiscard = false; close() }
            }
        } message: { Text("Your unsaved status names will be discarded. Your notes and tasks stay as they are.") }
        .onAppear {
            if let target = notebook.settingsDestination, let requested = SettingsSection(rawValue: target) { section = requested; notebook.settingsDestination = nil }
            if let url = notebook.selected, let page = try? TaskDocument(markdown: notebook.text) {
                pageURL = url; pagePreferences = page.preferences
                scope = "page"
            }
            loadRows()
        }
    }
    private func close() { notebook.showingSettings = false; DispatchQueue.main.async { notebook.richEditor?.focus() } }
    private func leave() { if notebook.gitSyncing { return }; if changes { closeAfterDiscard = true; confirmingDiscard = true } else { close() } }
    private func navigation(compact: Bool) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 0) {
                Button { leave() } label: {
                    HStack(spacing: 6 * scale) {
                        OpusIcon(glyph: "\u{f104}", size: 10 * scale)
                        if !compact { Text("Back to notes").font(.system(size: 10 * scale)) }
                    }.padding(.vertical, 7 * scale).contentShape(Rectangle())
                }.buttonStyle(.plain).foregroundStyle(muted).help("Back to notes").accessibilityLabel("Back to notes")
                Spacer(minLength: 0)
            }.padding(.leading, notebook.fullscreen || compact ? 8 * scale : 72)
                .padding(.top, compact && !notebook.fullscreen ? 30 : max(0, 19 - 13 * scale))
                .frame(height: compact && !notebook.fullscreen ? 66 : min(40 * scale, 56), alignment: .top).background(WindowDragRegion())
            if !compact { Text("Settings").font(.system(size: 14 * scale, weight: .semibold)).padding(.top, 16 * scale).padding(.bottom, 12 * scale).padding(.leading, 9 * scale) }
            VStack(spacing: 2 * scale) {
                ForEach(SettingsSection.allCases) { item in
                    Button { section = item } label: {
                        HStack(spacing: 10 * scale) {
                            OpusIcon(glyph: item.glyph, size: 11 * scale).foregroundStyle(section == item ? accent : muted)
                            if !compact { Text(item.rawValue).font(.system(size: 11 * scale)).lineLimit(1); Spacer(minLength: 0) }
                        }
                        .frame(maxWidth: .infinity, alignment: compact ? .center : .leading)
                        .padding(.horizontal, 9 * scale).padding(.vertical, 8 * scale)
                        .background(section == item ? accent.opacity(0.12) : .clear, in: RoundedRectangle(cornerRadius: 5 * scale))
                        .contentShape(Rectangle())
                    }.buttonStyle(.plain).help(item.rawValue).accessibilityLabel(item.rawValue).accessibilityAddTraits(section == item ? [.isSelected] : [])
                }
            }
            Spacer()
            if !compact { Text("OMEGA").font(.system(size: 9 * scale, weight: .medium)).tracking(2).foregroundStyle(muted.opacity(0.6)).padding(9 * scale).padding(.bottom, 9 * scale) }
        }.padding(.horizontal, compact ? 7 : 12 * scale).background(Color(nsColor: Ink.sidebar))
            .overlay(alignment: .trailing) { Rectangle().fill(Color(nsColor: Ink.separator)).frame(width: 1) }
    }
    @ViewBuilder private var content: some View {
        switch section {
        case .appearance: appearanceCards
        case .tasks: taskCards
        case .labels: SettingsLabelsView(notebook: notebook)
        case .storage: storageCards
        case .assistants: assistantCards
        case .git: SettingsGitView(notebook: notebook)
        case .about: aboutCards
        }
    }
    private func card<Content: View>(_ title: String, subtitle: String? = nil, @ViewBuilder content: () -> Content) -> some View {
        SettingsCard(title, subtitle: subtitle, scale: scale, content: content)
    }
    private var appearanceCards: some View {
        VStack(spacing: 20 * scale) {
            card("Theme", subtitle: "Choose a light or dark page, or follow your Mac.") {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 12 * scale) { ForEach(["system", "light", "dark"], id: \.self) { themeChoice($0) } }.frame(minWidth: 380 * scale)
                    VStack(spacing: 12 * scale) { ForEach(["system", "light", "dark"], id: \.self) { themeChoice($0) } }
                }
            }
            card("Document text", subtitle: "Change your writing size and typeface. Sidebar and controls keep their size.") {
                Picker("Typeface", selection: Binding(get: { notebook.writingFont }, set: { notebook.setWriting(font: $0) })) {
                    Text("Default").tag("default"); Text("Serif").tag("serif"); Text("Mono").tag("mono")
                }.pickerStyle(.segmented)
                HStack(spacing: 10 * scale) {
                    Text("Text size"); Spacer(minLength: 12)
                    Button { notebook.changeWritingSize(-1) } label: { Image(systemName: "minus").frame(width: 20 * scale, height: 20 * scale) }.accessibilityLabel("Smaller document text").disabled(notebook.writingScale <= 0.8)
                    Text("\(Int((notebook.writingScale * 100).rounded()))%").monospacedDigit().frame(minWidth: 42 * scale)
                    Button { notebook.changeWritingSize(1) } label: { Image(systemName: "plus").frame(width: 20 * scale, height: 20 * scale) }.accessibilityLabel("Larger document text").disabled(notebook.writingScale >= 1.8)
                }
                Toggle("Wide documents", isOn: Binding(get: { notebook.writingWide }, set: { notebook.setWriting(wide: $0) })).toggleStyle(.switch)
                Text("⌥⌘ + and ⌥⌘ − · Also available from Aa on any note.").font(.system(size: 10 * scale)).foregroundStyle(muted)
            }
            card("Interface size", subtitle: "Adjust the text and controls across the whole app.") {
                HStack(spacing: 10 * scale) {
                    Button { notebook.changeZoom(-1) } label: { Image(systemName: "minus").frame(width: 20 * scale, height: 20 * scale) }.accessibilityLabel("Smaller interface").disabled(notebook.zoom <= 0.7)
                    Text("\(Int((notebook.zoom * 100).rounded()))%").font(.system(size: 13 * scale, weight: .medium)).monospacedDigit().frame(minWidth: 42 * scale)
                    Button { notebook.changeZoom(1) } label: { Image(systemName: "plus").frame(width: 20 * scale, height: 20 * scale) }.accessibilityLabel("Larger interface").disabled(notebook.zoom >= 2.5)
                    Spacer(minLength: 0)
                }
                Button("Reset to default") { notebook.changeZoom(0) }.buttonStyle(.plain).foregroundStyle(muted)
                Text("⌘ + to increase · ⌘ − to decrease").font(.system(size: 10 * scale)).foregroundStyle(muted)
            }
        }
    }
    private func themeChoice(_ theme: String) -> some View {
        Button { notebook.setAppearance(theme) } label: {
            VStack(alignment: .leading, spacing: 9 * scale) {
                HStack(spacing: 0) {
                    Rectangle().fill(theme == "light" ? Color(white: 0.94) : Color(white: 0.12)).frame(width: 25 * scale)
                    VStack(alignment: .leading, spacing: 6 * scale) {
                        RoundedRectangle(cornerRadius: 1).fill(Color.gray.opacity(0.45)).frame(width: 33 * scale, height: 4 * scale)
                        RoundedRectangle(cornerRadius: 1).fill(Color.gray.opacity(0.20)).frame(height: 3 * scale)
                        RoundedRectangle(cornerRadius: 1).fill(Color.gray.opacity(0.20)).frame(width: 42 * scale, height: 3 * scale)
                    }.padding(12 * scale).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                        .background(theme == "dark" ? Color(white: 0.19) : Color(white: 0.995))
                }.frame(height: 65 * scale).clipShape(RoundedRectangle(cornerRadius: 4 * scale))
                HStack { Text(theme.capitalized); Spacer(); Image(systemName: notebook.appearance == theme ? "checkmark.circle.fill" : "circle").foregroundStyle(notebook.appearance == theme ? accent : muted.opacity(0.5)) }
                    .font(.system(size: 11 * scale))
            }.padding(9 * scale).frame(maxWidth: .infinity)
                .overlay(RoundedRectangle(cornerRadius: 6 * scale).stroke(notebook.appearance == theme ? accent.opacity(0.6) : Color(nsColor: Ink.separator), lineWidth: 1))
                .contentShape(Rectangle())
        }.buttonStyle(.plain).accessibilityLabel("\(theme.capitalized) theme").accessibilityAddTraits(notebook.appearance == theme ? [.isSelected] : [])
    }
    private var taskCards: some View {
        VStack(spacing: 20 * scale) {
            SettingsCard("Task statuses", subtitle: "Keep the steps that match the way you work.", scale: scale) {
                Picker("Apply statuses to", selection: Binding(get: { scope }, set: { next in
                    if changes { pendingScope = next; confirmingDiscard = true } else { scope = next; loadRows() }
                })) {
                    Text("New task pages").tag("defaults")
                    if pagePreferences != nil { Text("Current task page").tag("page") }
                }.pickerStyle(.menu)
                if scope == "page", let pageURL { Text(pageURL.deletingPathExtension().lastPathComponent).font(.system(size: 11 * scale)).foregroundStyle(muted).lineLimit(2) }
                HStack { Text("Status"); Spacer(); Text("Completed").font(.system(size: 10 * scale)); Color.clear.frame(width: 22 * scale) }.foregroundStyle(muted)
                ForEach($rows) { $row in
                    HStack(spacing: 10 * scale) {
                        TextField("Status name", text: $row.name).textFieldStyle(.plain).padding(7 * scale)
                            .background(Color(nsColor: Ink.paper), in: RoundedRectangle(cornerRadius: 4 * scale))
                            .overlay(RoundedRectangle(cornerRadius: 4 * scale).stroke(Color(nsColor: Ink.separator), lineWidth: 1))
                        Button {
                            if row.id == completedID { return }
                            if !completedAlsoIDs.insert(row.id).inserted { completedAlsoIDs.remove(row.id) }
                        } label: {
                            Image(systemName: (completedID == row.id || completedAlsoIDs.contains(row.id)) ? "checkmark.circle.fill" : "circle").foregroundStyle((completedID == row.id || completedAlsoIDs.contains(row.id)) ? accent : muted).frame(width: 30 * scale)
                        }.buttonStyle(.plain).accessibilityLabel("Count \(row.name) as complete").help("More than one status can count as complete")
                        Button { rows.removeAll { $0.id == row.id }; if completedID == row.id { completedID = rows.last?.id } } label: {
                            Image(systemName: "minus").foregroundStyle(muted).frame(width: 18 * scale)
                        }.buttonStyle(.plain).disabled(rows.count == 1).accessibilityLabel("Remove \(row.name) status")
                    }
                }
            } footer: {
                VStack(alignment: .leading, spacing: 10 * scale) {
                    Picker("Default completion", selection: $completedID) {
                        ForEach(rows.filter { $0.id == completedID || completedAlsoIDs.contains($0.id) }) { row in Text(row.name).tag(Optional(row.id)) }
                    }.onChange(of: completedID) { old, new in if let old, rows.contains(where: { $0.id == old }) { completedAlsoIDs.insert(old) }; if let new { completedAlsoIDs.remove(new) } }
                    Text("Checked statuses count toward progress and unblock dependent tasks.").foregroundStyle(muted)
                    HStack { addStatus; Spacer(); saveStatuses }
                    Text(message.isEmpty ? "Renaming keeps tasks in place. Move tasks before removing their status." : message)
                        .foregroundStyle(hasError ? Color.red : muted).fixedSize(horizontal: false, vertical: true)
                }
            }
            card("Goals, connected to work", subtitle: "Link a goal from a task or subtask’s Goals picker. Progress updates from each linked item’s status.") {
                Text("Find all goals in your task page’s header. Linking a parent task does not automatically link its subtasks.").font(.system(size: 11 * scale)).foregroundStyle(muted).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
    private var addStatus: some View { Button { rows.append(StatusDraft(name: "")) } label: { Label("Add status", systemImage: "plus") }.buttonStyle(.plain).foregroundStyle(muted).disabled(rows.count >= 12) }
    private var saveStatuses: some View { Button(saving ? "Saving…" : "Save statuses", action: save).disabled(saving || !changes) }
    private var storageCards: some View {
        VStack(spacing: 20 * scale) {
            card("Notebooks", subtitle: "Notes are ordinary Markdown files. These are their locations on your Mac.") {
                if notebook.roots.isEmpty { Text("No notebooks open yet.").foregroundStyle(muted) }
                ForEach(notebook.roots, id: \.path) { root in
                    HStack(alignment: .top, spacing: 10 * scale) {
                        OpusIcon(glyph: "\u{f02d}", size: 13 * scale).foregroundStyle(Color(nsColor: notebook.tint(for: root).color))
                        VStack(alignment: .leading, spacing: 5 * scale) { Text(root.lastPathComponent).fontWeight(.medium); Text(root.path).font(.system(size: 10 * scale)).foregroundStyle(muted).textSelection(.enabled).fixedSize(horizontal: false, vertical: true) }
                        Spacer(minLength: 0)
                        Button { NSWorkspace.shared.activateFileViewerSelecting([root]) } label: { Image(systemName: "arrow.up.right").foregroundStyle(muted) }.buttonStyle(.plain).accessibilityLabel("Show \(root.lastPathComponent) in Finder")
                    }.padding(.vertical, 5 * scale)
                }
            }
            card("Saved locally", subtitle: "Edits use local recovery checkpoints and persistent undo history. App updates back up your notes and settings before replacing Omega.") {
                Button("Show recovery & history") { NSWorkspace.shared.activateFileViewerSelecting([notebook.recovery.directory]) }
                Button("Show update backups") { let folder = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Folio Updates"); NSWorkspace.shared.activateFileViewerSelecting([folder]) }
            }
        }
    }
    private var assistantCards: some View {
        VStack(spacing: 20 * scale) {
            card("Local assistant access", subtitle: "Allow connected tools such as Claude Code and Codex to read and manage the notebooks you have open.") {
                Toggle("Allow assistant access", isOn: Binding(get: { assistantEnabled }, set: { (NSApp.delegate as? AppDelegate)?.setAssistantAccess($0) })).toggleStyle(.switch)
                Text(assistantEnabled ? "Access is on. Connected assistants can work with notes, tasks, subtasks, goals, and their links." : "Access is off. Your notes stay available to you in Omega.").font(.system(size: 11 * scale)).foregroundStyle(muted).fixedSize(horizontal: false, vertical: true)
            }
            AgentWorkflowSettings(notebook: notebook, scale: scale)
            card("Connect an assistant", subtitle: "Add Omega’s local MCP configuration to your assistant client, then reconnect the client.") {
                Button(copied ? "Configuration copied" : "Copy MCP configuration") {
                    let config: [String: Any] = ["mcpServers": ["folio": ["command": Bundle.main.executableURL!.path, "args": ["--mcp"]]]]
                    if let data = try? JSONSerialization.data(withJSONObject: config, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]) {
                        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(String(decoding: data, as: UTF8.self), forType: .string); copied = true
                    }
                }
                Text("Assistant edits use the same local saves and undo history. Conflicting changes are rejected.").font(.system(size: 11 * scale)).foregroundStyle(muted).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
    private var aboutCards: some View {
        VStack(spacing: 20 * scale) {
            card("Omega") {
                HStack(spacing: 16 * scale) {
                    if let icon = NSImage(named: NSImage.Name("NSApplicationIcon")) { Image(nsImage: icon).resizable().frame(width: 56 * scale, height: 56 * scale) }
                    VStack(alignment: .leading, spacing: 5 * scale) {
                        Text("Simply yours.").font(.system(size: 16 * scale, weight: .medium))
                        Text("Version \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "")").foregroundStyle(muted)
                    }
                }
            }
            UpdateSettingsView(scale: scale)
            HStack {
                Text("Open source · Apache 2.0").foregroundStyle(muted)
                Spacer()
                Button("View on GitHub") { NSWorkspace.shared.open(OmegaReleaseFeed.home) }.buttonStyle(.plain)
            }.font(.system(size: 10 * scale))
        }
    }
    private func loadRows() {
        baseline = scope == "page" ? (pagePreferences ?? notebook.taskPreferences) : notebook.taskPreferences
        rows = baseline.statuses.map { StatusDraft(original: $0, name: $0) }
        completedID = rows.first(where: { $0.name == baseline.completed })?.id
        completedAlsoIDs = Set(rows.filter { (baseline.completedAlso ?? []).contains($0.name) }.map(\.id))
        message = ""; hasError = false
    }
    private func save() {
        let value = TaskPreferences(statuses: rows.map(\.name), completed: rows.first(where: { $0.id == completedID })?.name ?? "", completedAlso: additionalCompleted.isEmpty ? nil : additionalCompleted)
        do { try value.validate() } catch { message = error.localizedDescription; hasError = true; return }
        let renames = Dictionary(uniqueKeysWithValues: rows.compactMap { row in row.original.map { ($0, row.name) } })
        saving = true
        let finish: (String?) -> Void = { error in
            saving = false; hasError = error != nil
            if let error { message = error }
            else {
                if scope == "page" { pagePreferences = value }
                loadRows(); message = "Statuses saved."
            }
        }
        if scope == "page", let pageURL {
            notebook.configureCurrentTasks(value, at: pageURL, expected: baseline, renames: renames, completion: finish)
        } else {
            do { try notebook.saveTaskPreferences(value); finish(nil) }
            catch { finish(error.localizedDescription) }
        }
    }
}
