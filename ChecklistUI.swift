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
    var body: some View { FolderTasksEditor(folder: folder, notebook: notebook).background(Color(nsColor: Ink.paper)) }
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
