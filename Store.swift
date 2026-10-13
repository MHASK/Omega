import SwiftUI
import AppKit
import UniformTypeIdentifiers

// Watch the file and its directory: editors commonly save by replacing the
// inode. Re-arm the file watch after every directory event, with polling as a
// fallback for volumes that don't deliver filesystem notifications.
@MainActor final class OpenNoteWatcher {
    private var sources: [DispatchSourceFileSystemObject] = []
    private var pending: DispatchWorkItem?
    deinit { pending?.cancel(); sources.forEach { $0.cancel() } }
    func stop() { pending?.cancel(); pending = nil; sources.forEach { $0.cancel() }; sources = [] }
    func watch(_ url: URL?, changed: @escaping () -> Void) {
        stop(); guard let url else { return }
        for target in [url, url.deletingLastPathComponent()] {
            let fd = open(target.path, O_EVTONLY)
            guard fd >= 0 else { continue }
            let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .rename, .delete, .extend, .attrib], queue: .main)
            source.setCancelHandler { close(fd) }
            source.setEventHandler { [weak self] in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.pending?.cancel()
                    let work = DispatchWorkItem { [weak self] in
                        self?.watch(url, changed: changed)
                        changed()
                    }
                    self.pending = work
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.08, execute: work)
                }
            }
            sources.append(source); source.resume()
        }
    }
}

struct NoteUpdateActivity: Equatable {
    let id = UUID()
    let file: URL
    let message: String
    let pending: Bool
}

struct LibraryPreferences: Codable {
    var favorites: Set<String> = []
    var archived: Set<String> = []
    var order: [String: [String]]?
}

@MainActor
final class Notebook: ObservableObject {
    @Published var root: URL?
    @Published var notebooks: [URL] = []
    @Published var trees: [URL: [NoteEntry]] = [:]
    @Published var collapsedNotebooks: Set<String> = []
    @Published var creationFolder: URL?
    @Published private(set) var notebookTints = UserDefaults.standard.dictionary(forKey: "notebookColors") as? [String: String] ?? [:]
    func tint(for url: URL) -> NotebookTint { NotebookTint(rawValue: notebookTints[url.path] ?? "") ?? .sky }
    func setTint(_ tint: NotebookTint?, for url: URL) {
        let used = Set(roots.compactMap { notebookTints[$0.path] })
        let unused = NotebookTint.allCases.filter { !used.contains($0.rawValue) }
        let alternatives = NotebookTint.allCases.filter { $0.rawValue != notebookTints[url.path] }
        let chosen = tint ?? (unused.isEmpty ? alternatives : unused).randomElement() ?? .sky
        notebookTints[url.path] = chosen.rawValue
        UserDefaults.standard.set(notebookTints, forKey: "notebookColors")
    }
    @Published var sidebarWidth = UserDefaults.standard.object(forKey: "sidebarWidth") as? Double ?? 215
    var visibleSidebarWidth: CGFloat = 215
    let recovery: DraftRecovery
    lazy var history = UndoHistory(file: recovery.directory.appendingPathComponent("History/undo.sqlite"))
    lazy var deletedNotes = DeletedNotes(directory: recovery.directory.appendingPathComponent("History/Deleted Notes"))
    private var recentDeletion = false
    private var historyError: String?
    @Published var library = LibraryPreferences()
    @Published var archiveExpanded = false
    @Published var taskPreferences = TaskPreferences()
    @Published var labelColors: [String: Int] = [:]
    init(recovery: DraftRecovery = DraftRecovery()) {
        self.recovery = recovery
        if let data = try? Data(contentsOf: recovery.directory.appendingPathComponent("Settings/labels.json")),
           let colors = try? JSONDecoder().decode([String: Int].self, from: data) { labelColors = colors.filter { LabelPastel(rawValue: $0.value) != nil } }
        if let data = try? Data(contentsOf: recovery.directory.appendingPathComponent("Settings/tasks.json")),
           let saved = try? JSONDecoder().decode(TaskPreferences.self, from: data), (try? saved.validate()) != nil { taskPreferences = saved }
        if let data = try? Data(contentsOf: recovery.directory.appendingPathComponent("Library/state.json")),
           let saved = try? JSONDecoder().decode(LibraryPreferences.self, from: data) { library = saved }
    }
    func saveTaskPreferences(_ value: TaskPreferences) throws {
        try value.validate()
        let directory = recovery.directory.appendingPathComponent("Settings")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try DraftRecovery.write(JSONEncoder().encode(value), to: directory.appendingPathComponent("tasks.json"))
        taskPreferences = value
    }
    func configureCurrentTasks(_ value: TaskPreferences, at file: URL, expected: TaskPreferences, renames: [String: String], completion: @escaping (String?) -> Void) {
        afterSync {
            do {
                guard self.selected == file else { throw TaskPageError("Return to the task page you opened Settings from, then try again.") }
                var document = try TaskDocument(markdown: self.text)
                guard TaskPreferences(statuses: document.statuses, completed: document.completedStatus) == expected else { throw TaskPageError("The page's statuses changed. Reopen Settings to use their latest names.") }
                try document.configure(value, renames: renames)
                let next = document.markdown
                if let editor = self.richEditor {
                    editor.replaceForAssistant(expected: self.text, text: next) { result in
                        do { try result.get(); try self.prepareAssistantAccess(); completion(nil) }
                        catch { completion(error.localizedDescription) }
                    }
                } else {
                    self.edit(next)
                    guard self.save() else { completion("Could not save the task page."); return }
                    self.revision = UUID(); completion(nil)
                }
            } catch { completion(error.localizedDescription) }
        }
    }
    func saveLibrary(_ value: LibraryPreferences) throws {
        try FileManager.default.createDirectory(at: recovery.directory.appendingPathComponent("Library"), withIntermediateDirectories: true)
        try DraftRecovery.write(JSONEncoder().encode(value), to: recovery.directory.appendingPathComponent("Library/state.json"))
        library = value
    }
    func isArchived(_ url: URL) -> Bool {
        library.archived.contains { url.path == $0 || url.path.hasPrefix($0 + "/") }
    }
    func activeEntries(_ items: [NoteEntry]) -> [NoteEntry] {
        orderedEntries(items).filter { !isArchived($0.url) }.map { item in
            var item = item; item.children = activeEntries(item.children); return item
        }
    }
    func orderedEntries(_ items: [NoteEntry]) -> [NoteEntry] {
        guard let parent = items.first?.url.deletingLastPathComponent(), let order = library.order?[parent.path] else { return items }
        let ranks = Dictionary(order.enumerated().map { ($0.element, $0.offset) }, uniquingKeysWith: { first, _ in first })
        return items.enumerated().sorted {
            let a = ranks[$0.element.url.path] ?? (order.count + $0.offset), b = ranks[$1.element.url.path] ?? (order.count + $1.offset)
            return a < b
        }.map(\.element)
    }
    func reorderItem(_ source: URL, beside target: URL, after: Bool) throws {
        let folder = source.deletingLastPathComponent()
        guard source != target, folder == target.deletingLastPathComponent(), owner(of: source) != nil, !roots.contains(source) else { return }
        var items = orderedEntries(try NoteFiles.scan(folder)).map(\.url)
        guard items.contains(source), items.contains(target) else { return }
        items.removeAll { $0 == source }; let index = items.firstIndex(of: target)!
        items.insert(source, at: index + (after ? 1 : 0))
        var updated = library; if updated.order == nil { updated.order = [:] }; updated.order?[folder.path] = items.map(\.path)
        try saveLibrary(updated)
    }
    func shiftItem(_ url: URL, down: Bool) {
        do {
            let items = orderedEntries(try NoteFiles.scan(url.deletingLastPathComponent())).filter { !isArchived($0.url) }
            guard let index = items.firstIndex(where: { $0.url == url }), items.indices.contains(index + (down ? 1 : -1)) else { return }
            try reorderItem(url, beside: items[index + (down ? 1 : -1)].url, after: down)
        } catch { showError(error) }
    }
    var libraryEntries: [NoteEntry] {
        var seen = Set<String>()
        return roots.flatMap { NoteFiles.flatten(trees[$0] ?? []) }.filter { seen.insert($0.url.path).inserted }
    }
    var favoriteEntries: [NoteEntry] { libraryEntries.filter { !isArchived($0.url) && library.favorites.contains($0.url.path) } }
    var archivedEntries: [NoteEntry] {
        libraryEntries.filter { library.archived.contains($0.url.path) }
            .filter { item in !library.archived.contains { path in item.url.path != path && item.url.path.hasPrefix(path + "/") } }
    }
    func toggleFavorite(_ url: URL) {
        var updated = library
        if !updated.favorites.insert(url.path).inserted { updated.favorites.remove(url.path) }
        do { try saveLibrary(updated) } catch { showError(error) }
    }
    func reconcileArchivedSelection() {
        if let selected, isArchived(selected) { clearSelection(); selectFirstAvailable() }
    }
    func toggleArchive(_ url: URL) {
        afterSync {
            guard self.save(), !self.roots.contains(url) else { return }
            var updated = self.library
            if self.isArchived(url) {
                updated.archived = updated.archived.filter { url.path != $0 && !url.path.hasPrefix($0 + "/") }
            } else { updated.archived.insert(url.path) }
            do {
                try self.saveLibrary(updated)
                self.reconcileArchivedSelection()
            } catch { self.showError(error) }
        }
    }

    var roots: [URL] { notebooks.isEmpty ? root.map { [$0] } ?? [] : notebooks }
    func owner(of url: URL) -> URL? {
        roots.filter { url.path == $0.path || url.path.hasPrefix($0.path + "/") }.max { $0.path.count < $1.path.count }
    }
    func rememberNotebooks() {
        for folder in notebooks where NotebookTint(rawValue: notebookTints[folder.path] ?? "") == nil { setTint(nil, for: folder) }
        UserDefaults.standard.set(notebooks.map(\.path), forKey: "notebooks")
    }
    func resizeSidebar(_ width: Double) {
        sidebarWidth = min(500, max(160, width))
        UserDefaults.standard.set(sidebarWidth, forKey: "sidebarWidth")
    }
    func filteredEntries(in folder: URL) -> [NoteEntry] {
        let contents = activeEntries(trees[folder] ?? (folder == root ? entries : []))
        return query.isEmpty ? contents : NoteFiles.flatten(contents).filter { !$0.isFolder && $0.name.localizedCaseInsensitiveContains(query) }
    }
    @Published var entries: [NoteEntry] = []
    @Published var selected: URL? {
        didSet {
            guard oldValue != selected else { return }
            updateActivity = nil; externalConflict = false
            fileWatcher.watch(selected) { [weak self] in self?.refreshFromDisk(reload: false) }
        }
    }
    @Published var updateActivity: NoteUpdateActivity?
    private let fileWatcher = OpenNoteWatcher()
    private var externalConflict = false
    func showUpdate(_ message: String, at file: URL, pending: Bool = false) {
        guard selected == file else { return }
        let activity = NoteUpdateActivity(file: file, message: message, pending: pending)
        updateActivity = activity
        if !pending {
            DispatchQueue.main.asyncAfter(deadline: .now() + 8) { [weak self] in
                if self?.updateActivity?.id == activity.id { self?.updateActivity = nil }
            }
        }
    }
    @Published var text = ""
    @Published var documentComments = 0
    @Published var documentIsSource = false
    @Published var query = ""
    var settingsDestination: String?
    @Published var showingSettings = false
    @Published var gitSyncing = false
    @Published var searching = false
    @Published var searchReveal: SearchReveal?
    @Published var cursorLine = 1
    @Published var cursorColumn = 1
    var lineCount: Int { text.isEmpty ? 1 : text.components(separatedBy: "\n").count }
    @Published var expanded: Set<String> = []
    @Published var dirty = false
    @Published var sidebar = UserDefaults.standard.object(forKey: "sidebarVisible") as? Bool ?? true {
        didSet { UserDefaults.standard.set(sidebar, forKey: "sidebarVisible") }
    }
    @Published var compactLayout = false
    @Published var sidebarOverlay = false
    var sidebarIsVisible: Bool { compactLayout ? sidebarOverlay : sidebar }
    func toggleSidebar() {
        if compactLayout { sidebarOverlay.toggle() } else { sidebar.toggle() }
    }
    func adaptSidebar(compact: Bool) {
        guard compactLayout != compact else { return }
        compactLayout = compact; sidebarOverlay = false
    }
    @Published var fullscreen = false
    @Published var reading = false
    @Published var appearance = UserDefaults.standard.string(forKey: "appearance") ?? "light"
    @Published var status = "All changes saved"
    @Published var revision = UUID()
    @Published var loading = false
    @Published var draggedURL: URL?
    @Published var dragPoint = CGPoint.zero
    @Published var dragDestination: URL?
    @Published var dragPromotesNotebook = false
    @Published var dragOrderTarget: URL?
    @Published var dragOrderAfter = false
    var dropFrames: [URL: CGRect] = [:]
    var sidebarHeight: CGFloat = 0

    func updateDrag(_ url: URL, at point: CGPoint) {
        draggedURL = url; dragPoint = point; dragPromotesNotebook = false; dragOrderTarget = nil
        guard point.x >= 0, point.x <= visibleSidebarWidth, point.y >= 0, point.y <= sidebarHeight else { dragDestination = nil; return }
        let hit = dropFrames.filter { $0.value.contains(point) }.min { $0.value.height < $1.value.height }?.key
        if let hit, hit != url, !roots.contains(hit), hit.deletingLastPathComponent() == url.deletingLastPathComponent(), let frame = dropFrames[hit] {
            let offset = (point.y - frame.minY) / max(1, frame.height)
            if !isFolder(hit) || offset < 0.25 || offset > 0.75 {
                dragDestination = nil; dragOrderTarget = hit; dragOrderAfter = offset > 0.5; return
            }
        }
        if let hit { dragDestination = isFolder(hit) ? hit : hit.deletingLastPathComponent() }
        else if isFolder(url) && !roots.contains(url) { dragDestination = nil; dragPromotesNotebook = true }
        else { dragDestination = owner(of: url) }
        if dragDestination == url || dragDestination?.path.hasPrefix(url.path + "/") == true { dragDestination = nil }
    }

    func finishDrag() {
        let source = draggedURL, target = dragDestination, promote = dragPromotesNotebook, orderTarget = dragOrderTarget, after = dragOrderAfter
        draggedURL = nil; dragDestination = nil; dragPromotesNotebook = false; dragOrderTarget = nil
        guard let source else { return }
        if let orderTarget { do { try reorderItem(source, beside: orderTarget, after: after) } catch { showError(error) } }
        else if promote { promoteNotebook(source) }
        else if let target { moveItem(source, into: target) }
    }
    private var folderRequest = UUID()
    private var diskText = ""
    private var saveTask: DispatchWorkItem?
    private var timer: Timer?
    private var checking = false
    weak var richEditor: EditorBridge?
    static let defaultZoom = 1.4
    @Published var zoom = UserDefaults.standard.object(forKey: "documentZoom") as? Double ?? Notebook.defaultZoom

    @Published var writingScale = min(1.8, max(0.8, UserDefaults.standard.object(forKey: "writingScale") as? Double ?? 1))
    @Published var writingFont = UserDefaults.standard.string(forKey: "writingFont") ?? "default"
    @Published var writingWide = UserDefaults.standard.bool(forKey: "writingWide")
    func setWriting(scale: Double? = nil, font: String? = nil, wide: Bool? = nil) {
        if let scale, scale.isFinite { writingScale = min(1.8, max(0.8, scale)); UserDefaults.standard.set(writingScale, forKey: "writingScale") }
        if let font, ["default", "serif", "mono"].contains(font) { writingFont = font; UserDefaults.standard.set(font, forKey: "writingFont") }
        if let wide { writingWide = wide; UserDefaults.standard.set(wide, forKey: "writingWide") }
    }
    func changeWritingSize(_ direction: Int) { setWriting(scale: direction == 0 ? 1 : (writingScale * 10 + Double(direction)).rounded() / 10) }

    func changeZoom(_ direction: Int) {
        zoom = direction == 0 ? Self.defaultZoom : min(2.5, max(0.7, (zoom * 10 + Double(direction)).rounded() / 10))
        UserDefaults.standard.set(zoom, forKey: "documentZoom")
    }
    func setZoom(_ value: Double) {
        zoom = min(2.5, max(0.7, value)); UserDefaults.standard.set(zoom, forKey: "documentZoom")
    }

    func afterSync(_ action: @escaping () -> Void) {
        guard !gitSyncing else { return }
        if let richEditor { richEditor.synchronize { success in if success { action() } } }
        else { action() }
    }

    var count: Int { NoteFiles.flatten(entries).filter { !$0.isFolder }.count }
    var totalNoteCount: Int {
        // Count nested notes once even when a folder is also open as a notebook.
        Set(roots.flatMap { folder in
            NoteFiles.flatten(trees[folder] ?? (folder == root ? entries : []))
                .filter { !$0.isFolder }.map { $0.url.standardizedFileURL.path }
        }).count
    }
    var filtered: [NoteEntry] {
        if query.isEmpty { return entries }
        return NoteFiles.flatten(entries).filter { !$0.isFolder && $0.name.localizedCaseInsensitiveContains(query) }
    }

    func start() {
        notebooks = (UserDefaults.standard.stringArray(forKey: "notebooks") ?? []).map { URL(fileURLWithPath: $0) }
        do {
            let restored = try recovery.recover()
            for file in restored where owner(of: file) == nil {
                let folder = file.deletingLastPathComponent()
                if !notebooks.contains(folder) { notebooks.append(folder) }
            }
            if !restored.isEmpty { rememberNotebooks(); status = "Recovered \(restored.count) interrupted edit(s)" }
        } catch { showMessage("Some interrupted edits could not be restored yet. Their recovery copies are still safe. " + error.localizedDescription) }
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--folder"), args.count > i + 1 {
            loadFolder(URL(fileURLWithPath: args[i+1]))
        } else if let path = UserDefaults.standard.string(forKey: "lastFolder"), FileManager.default.fileExists(atPath: path) {
            loadFolder(URL(fileURLWithPath: path))
        } else {
            let folder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Folio/Notes")
            do {
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                let welcome = folder.appendingPathComponent("Start here.md")
                if !FileManager.default.fileExists(atPath: welcome.path) {
                    try Self.welcome.write(to: welcome, atomically: true, encoding: .utf8)
                    try "# Small things\n\nA place to notice the things that are easy to miss.\n\n- Light falling across the desk\n- A sentence worth remembering\n- An idea that needs a little time\n\n> Pay attention. There is always something here.\n".write(to: folder.appendingPathComponent("Small things.md"), atomically: true, encoding: .utf8)
                    let personal = folder.appendingPathComponent("Personal")
                    try FileManager.default.createDirectory(at: personal, withIntermediateDirectories: true)
                    try "# A slower Sunday\n\nNo grand plans. Just a little more room in the day.\n\n## The nice-to-haves\n\n- [ ] A walk without headphones\n- [ ] Read a few pages\n- [ ] Make something from scratch\n\nThe rest can wait.\n".write(to: personal.appendingPathComponent("A slower Sunday.md"), atomically: true, encoding: .utf8)
                    let projects = folder.appendingPathComponent("Projects")
                    try FileManager.default.createDirectory(at: projects, withIntermediateDirectories: true)
                    try "# An idea\n\nEvery good thing starts somewhere.\n\n## What if…\n\nWrite the rough version first.\n\n## Next step\n\n- [ ] Make the smallest possible version\n".write(to: projects.appendingPathComponent("An idea.md"), atomically: true, encoding: .utf8)
                }
                loadFolder(folder)
            } catch { showError(error) }
        }
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshFromDisk() }
        }
    }

    func loadFolder(_ url: URL, selecting preferred: URL? = nil) {
        afterSync { self.performLoadFolder(url, selecting: preferred) }
    }

    private func performLoadFolder(_ url: URL, selecting preferred: URL?) {
        guard save() else { return }
        let url = url.standardizedFileURL
        let request = UUID()
        folderRequest = request; loading = true
        let others = notebooks.filter { $0 != url }
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let otherTrees = Dictionary(uniqueKeysWithValues: others.map { ($0, (try? NoteFiles.scan($0)) ?? []) })
            let result = Result { try NoteFiles.scan(url) }
            DispatchQueue.main.async { [weak self] in
                guard let self, self.folderRequest == request else { return }
                self.loading = false
                switch result {
                case .success(let found):
                    guard self.save() else { return }
                    self.root = url; self.entries = found; self.query = ""; self.creationFolder = url
                    if !self.notebooks.contains(url) { self.notebooks.append(url) }
                    self.trees.merge(otherTrees, uniquingKeysWith: { _, new in new }); self.trees[url] = found
                    self.collapsedNotebooks.remove(url.path); self.rememberNotebooks()
                    UserDefaults.standard.set(url.path, forKey: "lastFolder")
                    let last = preferred?.path ?? UserDefaults.standard.string(forKey: "lastNote")
                    let files = NoteFiles.flatten(found).filter { !$0.isFolder }
                    let first = files.first(where: { $0.url.path == last }) ?? files.first(where: { $0.name == "Start here" }) ?? files.first
                    self.selected = nil; self.text = ""; self.diskText = ""; self.dirty = false
                    if let first { self.performSelect(first.url) }
                case .failure(let error): self.showError(error)
                }
            }
        }
    }

    func select(_ url: URL) {
        afterSync { self.performSelect(url) }
    }

    func selectLinkedItem(_ url: URL, kind: String, id: String) {
        afterSync {
            self.performSelect(url)
            if self.selected == url { self.richEditor?.queueItem(url, kind: kind, id: id) }
        }
    }

    func selectSearchResult(_ result: NoteSearchResult) {
        afterSync {
            self.performSelect(result.url)
            if self.selected == result.url, !self.searching, let anchor = result.anchor {
                self.searchReveal = SearchReveal(url: result.url, anchor: anchor)
            }
        }
    }

    private func performSelect(_ url: URL) {
        searchReveal = nil
        if url == selected { searching = false; query = ""; sidebarOverlay = false; return }
        guard save() else { return }
        do {
            let value = try String(contentsOf: url, encoding: .utf8)
            observeHistory(value, at: url)
            if let owner = owner(of: url) {
                root = owner; entries = trees[owner] ?? entries; collapsedNotebooks.remove(owner.path)
                UserDefaults.standard.set(owner.path, forKey: "lastFolder")
            }
            creationFolder = url.deletingLastPathComponent()
            searching = false; query = ""; cursorLine = 1; cursorColumn = 1
            selected = url; text = value; diskText = value; dirty = false; status = "All changes saved"
            sidebarOverlay = false
            revision = UUID()
            UserDefaults.standard.set(url.path, forKey: "lastNote")
            let recent = UserDefaults.standard.stringArray(forKey: "recentNotes") ?? []
            UserDefaults.standard.set(Array(([url.path] + recent.filter { $0 != url.path }).prefix(30)), forKey: "recentNotes")
            var parent = url.deletingLastPathComponent()
            while parent.path != root?.path && parent.path != "/" {
                expanded.insert(parent.path); parent.deleteLastPathComponent()
            }
        } catch { showError(error) }
    }

    func edit(_ value: String, beforeSelection: String = "", afterSelection: String = "", typing: Bool = false) {
        guard value != text else { return }
        recentDeletion = false
        if let selected {
            do { try history.record(before: text, after: value, at: selected, beforeSelection: beforeSelection, afterSelection: afterSelection, typing: typing) }
            catch { reportHistoryError(error) }
        }
        text = value; dirty = text != diskText
        status = dirty ? "Saving…" : "All changes saved"
        if let selected {
            do {
                if dirty { try recovery.checkpoint(text, original: diskText, file: selected) }
                else { recovery.clear(selected) }
            } catch {
                status = "Recovery copy unavailable — saving note now"
                if !save() { return }
            }
        }
        saveTask?.cancel()
        let task = DispatchWorkItem { [weak self] in _ = self?.save(automatically: true) }
        saveTask = task
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.55, execute: task)
    }

    private func reportHistoryError(_ error: Error) {
        let first = historyError == nil
        historyError = error.localizedDescription
        if first { showMessage("Your note will still be saved, but undo history could not be stored. " + error.localizedDescription) }
    }
    private func observeHistory(_ value: String, at url: URL) {
        do { try history.observe(value, at: url) } catch { reportHistoryError(error) }
    }
    func stepHistory(redo: Bool) throws -> UndoHistory.Travel? {
        guard let selected, !reading, save() else { return nil }
        // Reconcile changes made by another app before traversing history.
        refreshFromDisk()
        let result = try history.travel(at: selected, expected: text, redo: redo) { value in
            try self.recovery.checkpoint(value, original: self.diskText, file: selected)
        }
        guard let result else { status = redo ? "Nothing to redo" : "Beginning of this note’s history"; return nil }
        text = result.text; dirty = text != diskText
        _ = save()
        if !dirty { recovery.clear(selected) }
        return result
    }
    @discardableResult func undoRecentDeletion() -> Bool {
        guard recentDeletion else { return false }
        recentDeletion = false; restoreLastDeleted(); return true
    }
    func restoreLastDeleted() {
        afterSync {
            guard self.save() else { return }
            do {
                guard let entry = try self.deletedNotes.latest() else { self.status = "No deleted notes to restore"; return }
                let restored = try self.deletedNotes.restore(entry)
                try self.history.relocate(entry.backup, to: restored)
                if self.owner(of: restored) == nil { self.loadFolder(restored.deletingLastPathComponent()) }
                self.reloadTree(); self.expanded.insert(restored.deletingLastPathComponent().path)
                if !self.isFolder(restored) { self.performSelect(restored) }
                else { self.expanded.insert(restored.path) }
                self.status = "Restored “\(restored.lastPathComponent)”"
                self.recentDeletion = false
            } catch { self.showError(error) }
        }
    }

    @discardableResult
    func save(automatically: Bool = false) -> Bool {
        saveTask?.cancel()
        if checking { return false }
        guard dirty, let url = selected else { return true }
        do {
            guard FileManager.default.fileExists(atPath: url.path) else {
                status = "File moved or deleted — save a copy"
                return saveCopy()
            }
            let current = try String(contentsOf: url, encoding: .utf8)
            if current != diskText {
                if automatically {
                    refreshFromDisk(reload: false)
                    return false
                }
                let alert = NSAlert()
                alert.messageText = "This note changed outside Omega"
                alert.informativeText = "Keep both versions by saving your edits as a new file, or reload the version on disk."
                alert.addButton(withTitle: "Save My Copy")
                alert.addButton(withTitle: "Reload from Disk")
                alert.addButton(withTitle: "Cancel")
                switch alert.runModal() {
                case .alertFirstButtonReturn: return saveCopy()
                case .alertSecondButtonReturn:
                    // Keep the interrupted edits as a sibling before accepting the outside version.
                    let copy = NoteFiles.uniqueURL(in: url.deletingLastPathComponent(), name: url.deletingPathExtension().lastPathComponent + " (recovered)", ext: url.pathExtension)
                    try DraftRecovery.write(text, to: copy)
                    recovery.clear(url)
                    observeHistory(current, at: url)
                    text = current; diskText = current; dirty = false; externalConflict = false; updateActivity = nil; revision = UUID(); status = "Reloaded from disk"; reloadTree(); return true
                default: status = "Unsaved changes"; return false
                }
            }
            try DraftRecovery.write(text, to: url)
            recovery.clear(url)
            diskText = text; dirty = false; status = historyError == nil ? "All changes saved" : "Note saved · undo history unavailable"
            return true
        } catch {
            let preserved = recovery.hasCheckpoint(text, file: url)
            status = preserved ? "Draft saved locally · couldn’t update note" : "Couldn’t save"
            let error = error as NSError
            NSLog("Omega save failed: %@ (%ld); executable available: %@; draft preserved: %@", error.domain, error.code,
                  FolioUpdates.executablePath(getpid()) == nil ? "no" : "yes", preserved ? "yes" : "no")
            let alert = NSAlert()
            alert.messageText = "Couldn’t save “\(url.lastPathComponent)”"
            alert.informativeText = error.localizedDescription + (preserved ? "\n\nYour latest edits are safe in Omega’s local recovery copy. They remain available after restarting Omega." : "\n\nKeep this window open and use File → Save a Copy to preserve your edits.")
            alert.addButton(withTitle: "OK"); alert.runModal()
            return false
        }
    }

    @discardableResult
    func saveCopy() -> Bool {
        let panel = NSSavePanel()
        panel.title = "Save a copy"
        panel.nameFieldStringValue = (selected?.deletingPathExtension().lastPathComponent ?? "Untitled") + " copy.md"
        panel.directoryURL = selected?.deletingLastPathComponent() ?? root
        guard panel.runModal() == .OK, let url = panel.url else { return false }
        do {
            try DraftRecovery.write(text, to: url)
            observeHistory(text, at: url)
            if let selected { recovery.clear(selected) }
            selected = url; diskText = text; dirty = false; status = "All changes saved"; reloadTree()
            return true
        } catch { showError(error); return false }
    }

    func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false; panel.canChooseDirectories = true
        panel.prompt = "Open folder"; panel.message = "Your notes stay as plain files in this folder."
        if panel.runModal() == .OK, let url = panel.url { loadFolder(url) }
    }

    func chooseFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.plainText, UTType(filenameExtension: "md") ?? .plainText, UTType(filenameExtension: "markdown") ?? .plainText]
        panel.prompt = "Open note"
        if panel.runModal() == .OK, let url = panel.url { open(url) }
    }

    func open(_ url: URL) {
        var directory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &directory) else { return }
        if directory.boolValue { loadFolder(url); return }
        guard NoteFiles.extensions.contains(url.pathExtension.lowercased()), save() else { return }
        if owner(of: url) == nil {
            loadFolder(url.deletingLastPathComponent(), selecting: url)
        } else { select(url) }
    }

    func newNote(in folder: URL? = nil) {
        afterSync { self.performNewNote(in: folder) }
    }

    private func performNewNote(in folder: URL?) {
        guard save(), let directory = folder ?? creationFolder ?? root else { return }
        do {
            let url = NoteFiles.uniqueURL(in: directory)
            try "".write(to: url, atomically: true, encoding: .utf8)
            query = ""; reloadTree(); performSelect(url); reading = false
            DispatchQueue.main.async { self.richEditor?.focus() }
        } catch { showError(error) }
    }

    func newTaskPage(in folder: URL? = nil) {
        afterSync {
            guard self.save(), let directory = folder ?? self.root else { return }
            do {
                let url = NoteFiles.uniqueURL(in: directory, name: "Tasks")
                try DraftRecovery.write(TaskDocument(preferences: self.taskPreferences).markdown, to: url)
                self.query = ""; self.reloadTree(); self.performSelect(url); self.reading = false
            } catch { self.showError(error) }
        }
    }

    func newFolder(in folder: URL? = nil) {
        guard let parent = folder ?? creationFolder ?? root else { return }
        let alert = NSAlert(); alert.messageText = "New folder"
        let field = NSTextField(string: "Untitled folder")
        field.frame = NSRect(x: 0, y: 0, width: 280, height: 26)
        alert.accessoryView = field; alert.addButton(withTitle: "Create"); alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let name = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard NoteFiles.validName(name) else { showMessage("Choose a folder name without slashes, colons, or a leading dot."); return }
        do {
            let url = parent.appendingPathComponent(name, isDirectory: true)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
            expanded.insert(parent.path); expanded.insert(url.path)
            if let owner = owner(of: parent) { collapsedNotebooks.remove(owner.path) }
            reloadTree()
        } catch { showError(error) }
    }

    func newNotebook(beside folder: URL? = nil) {
        guard let current = folder ?? root else { chooseFolder(); return }
        let alert = NSAlert(); alert.messageText = "New notebook"
        alert.informativeText = "A separate folder beside \(current.lastPathComponent)."
        let field = NSTextField(string: "Notes")
        field.frame = NSRect(x: 0, y: 0, width: 280, height: 26)
        alert.accessoryView = field; alert.addButton(withTitle: "Create"); alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let name = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard NoteFiles.validName(name) else { showMessage("Choose a notebook name without slashes, colons, or a leading dot."); return }
        afterSync {
            guard self.save() else { return }
            do {
                let url = try self.createNotebook(named: name, beside: current)
                self.performLoadFolder(url, selecting: nil)
            } catch { self.showError(error) }
        }
    }

    @discardableResult func createNotebook(named name: String, beside current: URL) throws -> URL {
        guard NoteFiles.validName(name) else { throw CocoaError(.fileWriteInvalidFileName) }
        let url = current.deletingLastPathComponent().appendingPathComponent(name, isDirectory: true)
        // Existing notebooks must be opened explicitly, never mistaken for a new folder.
        guard !FileManager.default.fileExists(atPath: url.path) else { throw CocoaError(.fileWriteFileExists) }
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        if !notebooks.contains(current) { notebooks.append(current) }
        notebooks.append(url); trees[url] = []; collapsedNotebooks.remove(url.path); rememberNotebooks()
        return url
    }

    func rename(_ url: URL) {
        afterSync { self.performRename(url) }
    }

    private func performRename(_ url: URL) {
        guard save() else { return }
        let directory = isFolder(url)
        let alert = NSAlert()
        alert.messageText = roots.contains(url) ? "Rename notebook" : directory ? "Rename folder" : "Rename note"
        let field = NSTextField(string: directory ? url.lastPathComponent : url.deletingPathExtension().lastPathComponent)
        field.frame = NSRect(x: 0, y: 0, width: 280, height: 26)
        alert.accessoryView = field; alert.addButton(withTitle: "Rename"); alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        do { _ = try renameItem(url, to: field.stringValue) }
        catch { showError(error) }
    }

    func isFolder(_ url: URL) -> Bool { (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
    static func contains(_ parent: URL, _ item: URL) -> Bool { item.path == parent.path || item.path.hasPrefix(parent.path + "/") }

    @discardableResult func renameItem(_ url: URL, to proposed: String) throws -> URL {
        guard save() else { return url }
        let directory = isFolder(url)
        var name = proposed.trimmingCharacters(in: .whitespacesAndNewlines)
        if !directory && !url.pathExtension.isEmpty && name.lowercased().hasSuffix("." + url.pathExtension.lowercased()) {
            name = String(name.dropLast(url.pathExtension.count + 1))
        }
        guard NoteFiles.validName(name) else { throw CocoaError(.fileWriteInvalidFileName) }
        var target = url.deletingLastPathComponent().appendingPathComponent(name, isDirectory: directory)
        if !directory { target.appendPathExtension(url.pathExtension) }
        guard target.path != url.path else { return url }
        if FileManager.default.fileExists(atPath: target.path) {
            let sourceID = try url.resourceValues(forKeys: [.fileResourceIdentifierKey]).fileResourceIdentifier as? NSObject
            let targetID = try target.resourceValues(forKeys: [.fileResourceIdentifierKey]).fileResourceIdentifier as? NSObject
            // Permit a case-only rename on a case-insensitive volume, never overwrite a sibling.
            guard url.path.lowercased() == target.path.lowercased(), let sourceID, sourceID == targetID else { throw CocoaError(.fileWriteFileExists) }
        }
        try relocateItem(url, to: target)
        return target
    }

    func duplicate(_ url: URL) {
        afterSync { do { _ = try self.duplicateItem(url) } catch { self.showError(error) } }
    }
    @discardableResult func duplicateItem(_ url: URL) throws -> URL {
        guard save() else { return url }
        let directory = isFolder(url)
        let name = (directory ? url.lastPathComponent : url.deletingPathExtension().lastPathComponent) + " copy"
        let target = unusedURL(in: url.deletingLastPathComponent(), name: name, ext: directory ? nil : url.pathExtension)
        try FileManager.default.copyItem(at: url, to: target)
        expanded.insert(target.path); query = ""; reloadTree()
        if !directory { performSelect(target) }
        return target
    }
    private func unusedURL(in parent: URL, name: String, ext: String?) -> URL {
        var index = 1
        while true {
            var url = parent.appendingPathComponent(name + (index == 1 ? "" : " \(index)"), isDirectory: ext == nil)
            if let ext, !ext.isEmpty { url.appendPathExtension(ext) }
            if !FileManager.default.fileExists(atPath: url.path) { return url }
            index += 1
        }
    }

    func copyPath(_ url: URL) { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(url.path, forType: .string) }
    func trash(_ url: URL) {
        afterSync { do { _ = try self.trashItem(url) } catch { self.showError(error) } }
    }
    @discardableResult func trashItem(_ url: URL) throws -> URL? {
        guard save() else { return nil }
        // Master notebooks use Close notebook; their files stay on disk.
        guard !roots.contains(url), owner(of: url) != nil else { return nil }
        let affected = selected.map { Self.contains(url, $0) } ?? false
        let recoverable = try deletedNotes.prepare(url)
        try history.relocate(url, to: recoverable.backup)
        var trashed: NSURL?
        do { try FileManager.default.trashItem(at: url, resultingItemURL: &trashed) }
        catch { try? history.relocate(recoverable.backup, to: url); throw error }
        // An interrupted final marker is also recoverable when the original is gone.
        try? deletedNotes.complete(recoverable)
        notebooks.removeAll { Self.contains(url, $0) }
        trees = trees.filter { !Self.contains(url, $0.key) }
        expanded = expanded.filter { $0 != url.path && !$0.hasPrefix(url.path + "/") }
        if let creationFolder, Self.contains(url, creationFolder) { self.creationFolder = url.deletingLastPathComponent() }
        if let root, Self.contains(url, root) { self.root = notebooks.first }
        if affected { clearSelection() }
        rememberNotebooks(); reloadTree()
        if affected { selectFirstAvailable() }
        recentDeletion = true; status = "Moved to Trash · ⌘Z to restore"
        return trashed as URL?
    }

    func closeNotebook(_ folder: URL) {
        afterSync {
            guard self.save() else { return }
            let affected = self.selected.map { self.owner(of: $0) == folder } ?? false
            self.notebooks.removeAll { $0 == folder }; self.trees.removeValue(forKey: folder)
            self.collapsedNotebooks.remove(folder.path)
            if self.root == folder { self.root = self.notebooks.first }
            if let creation = self.creationFolder, Self.contains(folder, creation) { self.creationFolder = self.root }
            if affected { self.clearSelection() }
            self.entries = self.root.flatMap { self.trees[$0] } ?? []
            self.rememberNotebooks()
            UserDefaults.standard.set(self.root?.path, forKey: "lastFolder")
            if affected { self.selectFirstAvailable() }
        }
    }
    private func clearSelection() {
        saveTask?.cancel(); selected = nil; text = ""; diskText = ""; dirty = false; revision = UUID()
        cursorLine = 1; cursorColumn = 1; status = "All changes saved"
        UserDefaults.standard.removeObject(forKey: "lastNote")
    }
    private func selectFirstAvailable() {
        let candidates = root.map { [$0] } ?? []
        for folder in candidates + notebooks.filter({ !candidates.contains($0) }) {
            if let note = NoteFiles.flatten(trees[folder] ?? []).first(where: { !$0.isFolder && !isArchived($0.url) }) { performSelect(note.url); return }
        }
    }

    func promoteNotebook(_ folder: URL) {
        afterSync { do { _ = try self.promoteNotebookItem(folder) } catch { self.showError(error) } }
    }
    @discardableResult func promoteNotebookItem(_ folder: URL) throws -> URL {
        guard save(), isFolder(folder), let book = owner(of: folder), !roots.contains(folder) else { return folder }
        let target = unusedURL(in: book.deletingLastPathComponent(), name: folder.lastPathComponent, ext: nil)
        try relocateItem(folder, to: target, asNotebook: true)
        return target
    }

    func relocateItem(_ original: URL, to target: URL, asNotebook: Bool = false) throws {
        let notes = isFolder(original) ? NoteFiles.flatten(try NoteFiles.scan(original)).filter { !$0.isFolder }.map(\.url) : [original]
        var rewrites: [(old: URL, new: URL, before: String, after: String)] = []
        for old in notes {
            let new = URL(fileURLWithPath: target.path + String(old.path.dropFirst(original.path.count)))
            let before = try String(contentsOf: old, encoding: .utf8)
            let after = NoteFiles.rebaseLinks(before, from: old, to: new, moving: original, to: target)
            if before != after { rewrites.append((old, new, before, after)) }
        }
        try FileManager.default.moveItem(at: original, to: target)
        do {
            for change in rewrites { try DraftRecovery.write(change.after, to: change.new) }
            try history.relocate(original, to: target)
        }
        catch {
            do {
                for change in rewrites { try DraftRecovery.write(change.before, to: change.new) }
                try FileManager.default.moveItem(at: target, to: original)
            } catch { showMessage("The move could not be fully restored. Your files are at " + target.path) }
            reloadTree(); throw error
        }
        for change in rewrites { observeHistory(change.after, at: change.new) }
        func mapped(_ url: URL) -> URL {
            Self.contains(original, url) ? URL(fileURLWithPath: target.path + String(url.path.dropFirst(original.path.count)), isDirectory: url.hasDirectoryPath) : url
        }
        var updatedLibrary = library
        updatedLibrary.favorites = Set(library.favorites.map { mapped(URL(fileURLWithPath: $0)).path })
        updatedLibrary.archived = Set(library.archived.map { mapped(URL(fileURLWithPath: $0)).path })
        if let order = library.order {
            updatedLibrary.order = Dictionary(order.map { (mapped(URL(fileURLWithPath: $0.key)).path, $0.value.map { mapped(URL(fileURLWithPath: $0)).path }) }, uniquingKeysWith: { first, _ in first })
        }
        do { try saveLibrary(updatedLibrary) } catch { showError(error) }
        let recent = UserDefaults.standard.stringArray(forKey: "recentNotes") ?? []
        UserDefaults.standard.set(recent.map { mapped(URL(fileURLWithPath: $0)).path }, forKey: "recentNotes")
        let existingRoots = roots
        for (path, color) in notebookTints where Self.contains(original, URL(fileURLWithPath: path)) {
            notebookTints.removeValue(forKey: path); notebookTints[mapped(URL(fileURLWithPath: path)).path] = color
        }
        UserDefaults.standard.set(notebookTints, forKey: "notebookColors")
        notebooks = existingRoots.map(mapped)
        if asNotebook && !notebooks.contains(target) { notebooks.append(target) }
        trees = [:]
        if let root { self.root = mapped(root) }
        if let creationFolder { self.creationFolder = mapped(creationFolder) }
        expanded = Set(expanded.map { mapped(URL(fileURLWithPath: $0)).path })
        collapsedNotebooks = Set(collapsedNotebooks.map { mapped(URL(fileURLWithPath: $0)).path })
        if let selected, Self.contains(original, selected) {
            self.selected = mapped(selected)
            if let change = rewrites.first(where: { $0.old == selected }) { text = change.after; diskText = text }
            root = owner(of: self.selected!); revision = UUID()
            UserDefaults.standard.set(self.selected?.path, forKey: "lastNote")
        }
        if asNotebook { collapsedNotebooks.remove(target.path); creationFolder = target }
        expanded.insert(target.deletingLastPathComponent().path)
        if let owner = owner(of: target) { collapsedNotebooks.remove(owner.path) }
        UserDefaults.standard.set(root?.path, forKey: "lastFolder")
        rememberNotebooks(); query = ""; reloadTree()
    }

    func reloadTree() {
        for folder in roots {
            if let updated = try? NoteFiles.scan(folder) {
                if trees[folder] != updated { trees[folder] = updated }
                if folder == root && updated != entries { entries = updated }
            }
        }
    }

    func closeDeletedBySync(_ file: URL) {
        guard selected == file, !dirty else { return }
        LiveCollaboration.shared.stop()
        selected = nil; text = ""; diskText = ""; revision = UUID()
        status = "Deletion synced · original kept in Git history"
        UserDefaults.standard.removeObject(forKey: "lastNote")
    }

    func refreshFromDisk(reload: Bool = true) {
        guard !checking, !loading, !gitSyncing else { return }
        if reload { reloadTree() }
        guard let selected else { return }
        if let current = try? String(contentsOf: selected, encoding: .utf8), current != diskText {
            saveTask?.cancel()
            if let editor = richEditor {
                checking = true
                if !externalConflict { showUpdate("Receiving changes…", at: selected, pending: true) }
                editor.applyExternal(base: diskText, text: current) { [weak self] result in
                    guard let self else { return }
                    self.checking = false
                    guard self.selected == selected else { return }
                    switch result["status"] as? String {
                    case "applied":
                        guard let value = result["text"] as? String else { return }
                        // The accepted disk version is the merge baseline even if
                        // another atomic write has already arrived behind it.
                        self.diskText = current; self.externalConflict = false
                        self.edit(value); self.dirty = self.text != current
                        do {
                            if self.dirty { try self.recovery.checkpoint(self.text, original: current, file: selected) }
                            else { self.recovery.clear(selected) }
                        } catch { self.showError(error) }
                        self.showUpdate("Updated externally", at: selected)
                        self.status = self.dirty ? "Saving merged changes…" : "All changes saved"
                        if (try? String(contentsOf: selected, encoding: .utf8)) != current { self.refreshFromDisk(reload: false) }
                        else if self.dirty { _ = self.save(automatically: true) }
                    case "conflict":
                        self.externalConflict = true
                        self.showUpdate("Outside edits need review", at: selected, pending: true)
                        self.status = "Both versions are safe · review outside edits"
                    default:
                        self.showUpdate("Update waiting for this edit", at: selected, pending: true)
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                            if self?.selected == selected { self?.refreshFromDisk(reload: false) }
                        }
                    }
                }
                return
            }
            guard !dirty else { showUpdate("Outside edits need review", at: selected, pending: true); return }
            observeHistory(current, at: selected)
            text = current; diskText = current; revision = UUID(); status = "Updated from disk"
            showUpdate("Updated externally", at: selected)
        } else if !FileManager.default.fileExists(atPath: selected.path) {
            status = "File moved or deleted — edit to save a copy"
        }
    }

    func reviewOutsideEdits() { afterSync { _ = self.save() } }


    // Assistant requests run on the main actor, after the editor has synchronized.
    // Never show a modal conflict dialog or replace a divergent on-disk version.
    func prepareAssistantAccess() throws {
        guard !gitSyncing, !checking else { throw AssistantError("This notebook is receiving outside changes. Retry shortly.") }
        guard !loading else { throw AssistantError("Omega is opening a notebook. Retry shortly.") }
        if dirty, let selected {
            guard (try? String(contentsOf: selected, encoding: .utf8)) == diskText else {
                throw AssistantError("The open note has an unresolved outside edit. Resolve it in Omega first; both versions are preserved.")
            }
            try DraftRecovery.write(text, to: selected)
            recovery.clear(selected); diskText = text; dirty = false; saveTask?.cancel()
            status = "All changes saved"
        }
    }
    func acceptAssistantText(_ value: String, at url: URL) throws {
        let before = selected == url ? text : try String(contentsOf: url, encoding: .utf8)
        try history.record(before: before, after: value, at: url)
        if selected == url {
            try recovery.checkpoint(value, original: diskText, file: url)
            try DraftRecovery.write(value, to: url)
            text = value; diskText = value; dirty = false; saveTask?.cancel(); recovery.clear(url)
            status = "Updated by an assistant"
        } else { try DraftRecovery.write(value, to: url) }
        reloadTree()
    }

    func setAppearance(_ value: String) {
        appearance = value; UserDefaults.standard.set(value, forKey: "appearance")
    }

    func format(_ prefix: String, suffix: String = "") {
        reading = false
        if let richEditor {
            let commands = ["**": "bold", "*": "italic", "## ": "heading", "- [ ] ": "task"]
            if let command = commands[prefix] { richEditor.command(command) }
        }
    }

    func receiveDrop(_ providers: [NSItemProvider], into folder: URL) -> Bool {
        let type = UTType.fileURL.identifier
        let files = providers.filter { $0.hasItemConformingToTypeIdentifier(type) }
        guard !files.isEmpty else { return false }
        for provider in files {
            provider.loadItem(forTypeIdentifier: type, options: nil) { [weak self] item, _ in
                let url: URL?
                if let value = item as? URL { url = value }
                else if let data = item as? Data { url = URL(dataRepresentation: data, relativeTo: nil) }
                else if let value = item as? String { url = URL(string: value) }
                else { url = nil }
                guard let url, url.isFileURL else { return }
                DispatchQueue.main.async { self?.moveItem(url, into: folder) }
            }
        }
        return true
    }

    func receiveRootDrop(_ providers: [NSItemProvider]) -> Bool {
        let providers = providers.filter { $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) }
        for provider in providers {
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { [weak self] item, _ in
                let url: URL?
                if let value = item as? URL { url = value }
                else if let data = item as? Data { url = URL(dataRepresentation: data, relativeTo: nil) }
                else if let value = item as? String { url = URL(string: value) }
                else { url = nil }
                guard let url, url.isFileURL else { return }
                DispatchQueue.main.async {
                    guard let self else { return }
                    if self.isFolder(url) {
                        if self.owner(of: url) != nil { self.promoteNotebook(url) }
                        else {
                            do {
                                let folder = url.standardizedFileURL
                                let contents = try NoteFiles.scan(folder)
                                if !self.notebooks.contains(folder) { self.notebooks.append(folder) }
                                self.trees[folder] = contents; self.creationFolder = folder; self.collapsedNotebooks.remove(folder.path)
                                if self.root == nil { self.root = folder; self.entries = contents; self.selectFirstAvailable() }
                                self.rememberNotebooks()
                            } catch { self.showError(error) }
                        }
                    } else if let root = self.root { self.moveItem(url, into: root) }
                }
            }
        }
        return !providers.isEmpty
    }

    func moveItem(_ source: URL, into folder: URL) {
        afterSync { self.performMove(source, into: folder) }
    }

    private func performMove(_ source: URL, into folder: URL) {
        guard save(), root != nil else { return }
        let rootPaths = roots.map { $0.standardizedFileURL.resolvingSymlinksInPath().path }
        let original = source.standardizedFileURL.resolvingSymlinksInPath()
        let parent = folder.standardizedFileURL.resolvingSymlinksInPath()
        guard rootPaths.contains(where: { parent.path == $0 || parent.path.hasPrefix($0 + "/") }) else { return }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: original.path, isDirectory: &isDirectory) else { return }
        guard isDirectory.boolValue || NoteFiles.extensions.contains(original.pathExtension.lowercased()) else { return }
        guard !rootPaths.contains(original.path), original != parent, !parent.path.hasPrefix(original.path + "/") else { return }
        if original.deletingLastPathComponent() == parent { return }
        let internalMove = rootPaths.contains { original.path.hasPrefix($0 + "/") }
        var target = parent.appendingPathComponent(original.lastPathComponent)
        var index = 2
        while FileManager.default.fileExists(atPath: target.path) {
            let name = isDirectory.boolValue ? original.lastPathComponent : original.deletingPathExtension().lastPathComponent
            target = parent.appendingPathComponent("\(name) \(index)")
            if !isDirectory.boolValue { target.appendPathExtension(original.pathExtension) }
            index += 1
        }
        do {
            if internalMove { try relocateItem(original, to: target) }
            else { try FileManager.default.copyItem(at: original, to: target); reloadTree() }
            expanded.insert(parent.path)
            if let book = owner(of: parent) { collapsedNotebooks.remove(book.path) }
            query = ""
        } catch { showError(error) }
    }

    func reveal(_ url: URL? = nil) {
        if let target = url ?? selected ?? root { NSWorkspace.shared.activateFileViewerSelecting([target]) }
    }

    func showError(_ error: Error) { showMessage(error.localizedDescription) }
    func showMessage(_ message: String) {
        let alert = NSAlert(); alert.messageText = "Omega"; alert.informativeText = message; alert.runModal()
    }

    static let welcome = """
    # A little room to think.

    A thought, a list, the beginning of something.
    Whatever it is, it belongs here.

    ## Simply yours

    Omega is a quiet place for your words. Open a folder,
    pick a note, and start writing. That’s all there is to it.

    Your notes are **plain Markdown files** on your Mac.
    Every change is saved as you type.

    ## Make yourself at home

    - Create a note with ⌘N
    - Open your own folder with ⇧⌘O
    - Hide the sidebar with ⌘\\
    - Switch to reading with ⇧⌘P

    > Less in the way. More on the page.
    """
}
