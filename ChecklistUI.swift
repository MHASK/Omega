import SwiftUI
import AppKit

struct FolderTasksButton: View {
    let folder: URL
    @ObservedObject var notebook: Notebook
    let scale: CGFloat
    var body: some View {
        Button { notebook.showChecklist(in: folder) } label: {
            Image(systemName: "checklist").font(.system(size: 11 * scale))
                .foregroundStyle(Color(nsColor: notebook.checklistFolder == folder ? Ink.accent : Ink.muted))
                .frame(width: 24 * scale, height: 26 * scale).contentShape(Rectangle())
        }.buttonStyle(.plain).help("Tasks in " + folder.lastPathComponent).accessibilityLabel("View tasks in " + folder.lastPathComponent)
    }
}

@MainActor final class FolderChecklistModel: ObservableObject {
    @Published var groups: [ChecklistGroup] = []
    @Published var loading = true
    @Published var message: String?
    @Published var busy: String?
    private var scanning = false
    private var generation = UUID()
    func refresh(_ folder: URL, notebook: Notebook) {
        guard !scanning, busy == nil else { return }
        guard notebook.owner(of: folder) != nil, !notebook.isArchived(folder) else {
            groups = []; loading = false; message = "This folder is no longer active."; return
        }
        scanning = true
        let token = generation, archived = notebook.library.archived
        let selected = notebook.selected, text = notebook.text
        DispatchQueue.global(qos: .userInitiated).async {
            var skipped = 0
            let scan = Result { () -> [ChecklistGroup] in
                try NoteFiles.flatten(NoteFiles.scan(folder)).filter { entry in
                    !entry.isFolder && !archived.contains { entry.url.path == $0 || entry.url.path.hasPrefix($0 + "/") }
                }.compactMap { entry in
                    do {
                        let info = try entry.url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
                        guard info.isRegularFile == true, (info.fileSize ?? 0) <= 8_000_000 else { skipped += 1; return nil }
                        let source = entry.url == selected ? text : try String(contentsOf: entry.url, encoding: .utf8)
                        let items = NoteChecklist.items(in: source)
                        return items.isEmpty ? nil : ChecklistGroup(url: entry.url, source: source, items: items)
                    } catch { skipped += 1; return nil }
                }
            }
            DispatchQueue.main.async {
                guard self.generation == token else { return }
                self.scanning = false; self.loading = false
                switch scan {
                case .success(let groups):
                    if self.groups != groups { self.groups = groups }
                    if skipped > 0 { self.message = "\(skipped) notes could not be read." }
                case .failure: self.message = "This folder could not be read. Check that it is still available."
                }
            }
        }
    }
    func toggle(_ item: NoteChecklistItem, group: ChecklistGroup, notebook: Notebook) {
        guard busy == nil, !notebook.gitSyncing else { return }
        generation = UUID(); scanning = false
        busy = group.id + item.id; message = nil
        let finish: (String?) -> Void = { error in
            self.busy = nil; self.message = error
            if let folder = notebook.checklistFolder { self.refresh(folder, notebook: notebook) }
        }
        let perform = {
            do {
                try notebook.prepareAssistantAccess()
                let service = AssistantService(notebook)
                let url = try service.resolve(group.url.path, folder: false)
                let current = try String(contentsOf: url, encoding: .utf8)
                guard current == group.source else { throw TaskPageError("This note changed. The list has been refreshed; try the checkbox again.") }
                let completion: ([String: Any]) -> Void = { result in
                    let error = (result["content"] as? [[String: Any]])?.first?["text"] as? String
                    finish(result["isError"] as? Bool == true ? error ?? "Could not save this change." : nil)
                }
                let args: [String: Any] = ["path": url.path, "expected_revision": AssistantWire.hash(current)]
                if let reference = item.reference {
                    try service.mutateTasks("update_task", args.merging(["reference": reference, "completed": !item.completed]) { _, new in new }, completion: completion)
                } else {
                    let next = try NoteChecklist.toggled(item, in: current, expected: group.source)
                    try service.update(args.merging(["markdown": next]) { _, new in new }, completion: completion)
                }
            } catch { finish(error.localizedDescription) }
        }
        if let editor = notebook.richEditor { editor.synchronize { success in
            if success { perform() } else { finish("The editor is still saving. Try again in a moment.") }
        }} else { perform() }
    }
}

struct FolderChecklistView: View {
    let folder: URL
    @ObservedObject var notebook: Notebook
    @StateObject private var model = FolderChecklistModel()
    @State private var filter = "Open"
    var scale: CGFloat { min(CGFloat(notebook.zoom), 1.6) }
    var items: [NoteChecklistItem] { model.groups.flatMap(\.items) }
    var completed: Int { items.filter(\.completed).count }
    func visible(_ group: ChecklistGroup) -> [NoteChecklistItem] { group.items.filter { filter == "All" || $0.completed == (filter == "Done") } }
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12 * scale) {
                Button { notebook.checklistFolder = nil } label: { Image(systemName: "chevron.left").frame(width: 24 * scale, height: 28 * scale) }
                    .help("Back to note").accessibilityLabel("Back to note")
                Text(folder.lastPathComponent).foregroundStyle(Color(nsColor: Ink.muted)).lineLimit(1)
                Text("/").foregroundStyle(Color(nsColor: Ink.muted))
                Text("Tasks").fontWeight(.semibold)
                Spacer()
                Text("\(completed)/\(items.count)").monospacedDigit().foregroundStyle(Color(nsColor: Ink.muted))
                ZStack {
                    Circle().stroke(Color(nsColor: Ink.muted).opacity(0.2), lineWidth: 2)
                    Circle().trim(from: 0, to: items.isEmpty ? 0 : CGFloat(completed) / CGFloat(items.count))
                        .stroke(Color(nsColor: Ink.accent), style: StrokeStyle(lineWidth: 2, lineCap: .round)).rotationEffect(.degrees(-90))
                }.frame(width: 17 * scale, height: 17 * scale).accessibilityLabel("\(completed) of \(items.count) tasks completed")
            }.font(.system(size: 12 * scale)).padding(.horizontal, 22 * scale).frame(height: 50 * scale)
                .overlay(alignment: .bottom) { Divider() }
            HStack(spacing: 4 * scale) {
                ForEach(["Open", "Done", "All"], id: \.self) { value in
                    Button { filter = value } label: {
                        Text(value).padding(.horizontal, 12 * scale).padding(.vertical, 6 * scale)
                            .background(filter == value ? Color(nsColor: Ink.muted).opacity(0.12) : .clear, in: RoundedRectangle(cornerRadius: 5 * scale))
                    }.accessibilityAddTraits(filter == value ? [.isSelected] : [])
                }
                Spacer()
                Text("From notes in this folder").foregroundStyle(Color(nsColor: Ink.muted))
            }.font(.system(size: 11 * scale)).padding(.horizontal, 24 * scale).padding(.vertical, 16 * scale)
            if let message = model.message {
                HStack { Image(systemName: "info.circle"); Text(message); Spacer(); Button("Dismiss") { model.message = nil } }
                    .font(.system(size: 11 * scale)).foregroundStyle(Color(nsColor: Ink.muted)).padding(.horizontal, 28 * scale).padding(.bottom, 12 * scale)
            }
            if model.loading { ProgressView().controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity) }
            else if model.groups.allSatisfy({ visible($0).isEmpty }) {
                VStack(spacing: 12 * scale) {
                    Image(systemName: "checklist").font(.system(size: 27 * scale, weight: .light)).foregroundStyle(Color(nsColor: Ink.muted))
                    Text(items.isEmpty ? "A little room for what’s next" : filter == "Done" ? "Nothing completed yet" : "All caught up")
                        .font(.system(size: 18 * scale, weight: .semibold))
                    Text(items.isEmpty ? "Type /task in any note to start a checklist.\nItems from this folder and its subfolders appear here." : "Your tasks stay in their original notes.")
                        .font(.system(size: 12 * scale)).foregroundStyle(Color(nsColor: Ink.muted)).multilineTextAlignment(.center)
                    if items.isEmpty { Button("Create a note") { notebook.newNote(in: folder) }.padding(.top, 4 * scale) }
                }.frame(maxWidth: .infinity, maxHeight: .infinity).padding(24 * scale)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 24 * scale) {
                        ForEach(model.groups) { group in
                            if !visible(group).isEmpty {
                                VStack(alignment: .leading, spacing: 0) {
                                    Button { notebook.select(group.url) } label: {
                                        HStack(spacing: 7 * scale) {
                                            Image(systemName: "doc.text")
                                            Text(group.url.deletingPathExtension().path.replacingOccurrences(of: folder.path + "/", with: "")).lineLimit(1)
                                            Text("\(group.items.filter(\.completed).count)/\(group.items.count)").monospacedDigit()
                                            Spacer(); Image(systemName: "arrow.up.right").font(.system(size: 9 * scale))
                                        }.font(.system(size: 11 * scale)).foregroundStyle(Color(nsColor: Ink.muted)).padding(.vertical, 10 * scale)
                                    }.help("Open source note")
                                    Divider()
                                    ForEach(visible(group)) { item in row(item, group: group); Divider().opacity(0.5) }
                                }
                            }
                        }
                    }.padding(.horizontal, 28 * scale).padding(.bottom, 32 * scale)
                }
            }
        }.buttonStyle(.plain).foregroundStyle(Color(nsColor: Ink.text)).background(Color(nsColor: Ink.paper))
            .task(id: folder) {
                while !Task.isCancelled {
                    model.refresh(folder, notebook: notebook)
                    do { try await Task.sleep(for: .seconds(2)) } catch { break }
                }
            }
    }
    func row(_ item: NoteChecklistItem, group: ChecklistGroup) -> some View {
        HStack(spacing: 12 * scale) {
            Button { model.toggle(item, group: group, notebook: notebook) } label: {
                ZStack {
                    RoundedRectangle(cornerRadius: 4 * scale).fill(item.completed ? Color(nsColor: Ink.accent).opacity(0.65) : .clear)
                    RoundedRectangle(cornerRadius: 4 * scale).strokeBorder(Color(nsColor: Ink.muted).opacity(item.completed ? 0 : 0.65), lineWidth: 1)
                    if item.completed { Image(systemName: "checkmark").font(.system(size: 10 * scale, weight: .semibold)).foregroundStyle(Color(nsColor: Ink.paper)) }
                }.frame(width: 17 * scale, height: 17 * scale).padding(3 * scale).contentShape(Rectangle())
            }.disabled(model.busy != nil || notebook.gitSyncing).accessibilityLabel((item.completed ? "Reopen " : "Complete ") + plain(item.title))
            Button { notebook.openChecklistItem(item, in: group) } label: {
                Text(plain(item.title)).strikethrough(item.completed).foregroundStyle(Color(nsColor: item.completed ? Ink.muted : Ink.text))
                    .frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
            }.help("Open in source note")
        }.font(.system(size: 13 * scale)).padding(.leading, CGFloat(min(item.depth, 6)) * 18 * scale).padding(.vertical, 11 * scale)
    }
    func plain(_ title: String) -> String {
        NoteSearchIndex.clean(title)
    }
}

extension Notebook {
    func showChecklist(in folder: URL) {
        afterSync {
            guard self.save() else { return }
            NSApp.keyWindow?.makeFirstResponder(nil)
            self.creationFolder = folder; self.checklistFolder = folder; self.sidebarOverlay = false
        }
    }
    func openChecklistItem(_ item: NoteChecklistItem, in group: ChecklistGroup) {
        if let reference = item.reference, let doc = try? TaskDocument(markdown: group.source),
           let ref = doc.references.first(where: { $0.reference == reference }), let id = ref.details.id {
            selectLinkedItem(group.url, kind: ref.kind, id: id); return
        }
        let tokens = NoteSearchIndex.words(item.title)
        guard let word = tokens.first else { select(group.url); return }
        let suffix = (group.source as NSString).substring(from: min(item.offset, group.source.utf16.count))
        let found = (suffix as NSString).range(of: word, options: [.caseInsensitive, .diacriticInsensitive])
        let anchor = NoteSearchAnchor(term: word, location: item.offset + (found.location == NSNotFound ? 0 : found.location), length: word.utf16.count, before: [], after: Array(tokens.dropFirst().prefix(5)))
        selectSearchResult(NoteSearchResult(url: group.url, root: owner(of: group.url) ?? group.url.deletingLastPathComponent(), title: item.title, location: "", snippet: "", terms: [], score: 0, anchor: anchor))
    }
}
