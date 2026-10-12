import Foundation
import AppKit
@main struct LibraryCheck {
    @MainActor static func main() throws {
        _ = NSApplication.shared
        let fm=FileManager.default, base=fm.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("Folio-Library-"+UUID().uuidString)
        defer {try? fm.removeItem(at:base)}
        let root=base.appendingPathComponent("Notes"), recovery=DraftRecovery(directory:base.appendingPathComponent("Recovery"))
        try fm.createDirectory(at:root,withIntermediateDirectories:true)
        let note=root.appendingPathComponent("Draft.md")
        try "Keep my text".write(to:note,atomically:true,encoding:.utf8)
        let store=Notebook(recovery:recovery);store.root=root;store.notebooks=[root];store.reloadTree();store.select(note)
        store.toggleFavorite(note);precondition(store.favoriteEntries.count==1)
        store.edit("Pending edit must survive archive")
        store.toggleArchive(note)
        precondition(store.isArchived(note)&&store.favoriteEntries.isEmpty&&store.archivedEntries.count==1&&store.filteredEntries(in:root).isEmpty)
        let archivedText=try String(contentsOf:note,encoding:.utf8);precondition(archivedText=="Pending edit must survive archive")
        let reopened=Notebook(recovery:recovery);reopened.root=root;reopened.notebooks=[root];reopened.reloadTree()
        precondition(reopened.isArchived(note)&&reopened.library.favorites.contains(note.path))
        let recovered=try recovery.recover();precondition(recovered.isEmpty)
        reopened.toggleArchive(note);precondition(!reopened.isArchived(note)&&reopened.favoriteEntries.count==1)
        let moved=try reopened.renameItem(note,to:"Renamed")
        precondition(reopened.library.favorites.contains(moved.path))
        reopened.toggleArchive(moved)
        let index=NoteSearchIndex();index.refresh(roots:[root],excluding:reopened.library.archived)
        precondition(index.documents.isEmpty)
        reopened.newTaskPage(in:root)
        let tasks=reopened.selected!
        precondition(tasks.lastPathComponent=="Tasks.md")
        precondition(reopened.text.hasPrefix("<!-- folio:tasks -->"))
        let scanned=try NoteFiles.scan(root);precondition(NoteFiles.flatten(scanned).first(where:{$0.url==tasks})?.isTaskPage==true)
        print("PASS: archive keeps files and pending edits, favorites/archives survive restart and rename, recovery remains clean, search excludes archived notes, task creation produces local Markdown")
    }
}
