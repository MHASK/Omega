import Foundation
import CryptoKit
import Darwin

// Explicit, local requests only. Shipping an update never implicitly moves a
// notebook. Run before constructing stores, starting Git, or accepting MCP.
final class NotebookMigration {
    struct Request: Codable, Equatable {
        let id: UUID
        let source: String
        let destination: String
        let minimumBuild: Int
    }
    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }
    struct Edit: Codable {
        let path: String
        let before: Data
        let after: Data
    }
    struct Transaction: Codable {
        let request: Request
        let device: UInt64
        let inode: UInt64
        let manifest: [String: String]
        let edits: [Edit]
        let preferences: [Edit]
    }
    let support: URL
    let defaults: UserDefaults
    var directory: URL { support.appendingPathComponent("Notebook Migrations") }
    var pendingFile: URL { directory.appendingPathComponent("pending.json") }
    // Test seam: terminate at durable boundaries and resume in a fresh process.
    var checkpoint: ((String) throws -> Void)?
    private let fm = FileManager.default
    init(support: URL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Folio"), defaults: UserDefaults = .standard) {
        self.support = support; self.defaults = defaults
    }
    func due(build: Int) throws -> Request? {
        guard fm.fileExists(atPath: pendingFile.path) else { return nil }
        let request = try JSONDecoder().decode(Request.self, from: Data(contentsOf: pendingFile))
        return build >= request.minimumBuild ? request : nil
    }
    func run(build: Int) throws {
        guard let request = try due(build: build) else { return }
        let lock = open(directory.appendingPathComponent("migration.lock").path, O_CREAT | O_RDWR, 0o600)
        guard lock >= 0 else { throw Failure(message: "Couldn’t open the notebook move lock.") }
        defer { close(lock) }
        guard flock(lock, LOCK_EX | LOCK_NB) == 0 else { throw Failure(message: "Another Omega instance is moving this notebook. Try again when it finishes.") }
        defer { flock(lock, LOCK_UN) }
        let source = URL(fileURLWithPath: request.source), target = URL(fileURLWithPath: request.destination)
        guard source.path == source.standardizedFileURL.path, target.path == target.standardizedFileURL.path,
              source.path != "/", target.path != "/", source != target,
              !target.path.hasPrefix(source.path + "/"), !source.path.hasPrefix(target.path + "/"),
              !directory.path.hasPrefix(source.path + "/"), !directory.path.hasPrefix(target.path + "/") else {
            throw Failure(message: "The requested notebook locations are invalid. No files were moved.")
        }
        let backup = directory.appendingPathComponent(request.id.uuidString)
        let journal = backup.appendingPathComponent("transaction.json")
        let done = backup.appendingPathComponent("completed.json")
        defer {
            // If preparation failed before the rename, keep its backup but
            // allow a fresh snapshot next launch (outside edits may continue).
            // A killed process skips this; its durable journal resumes normally.
            if exists(source), !exists(target),
               let saved = try? JSONDecoder().decode(Transaction.self, from: Data(contentsOf: journal)),
               saved.request == request, (try? matches(source, saved)) == true {
                try? fm.moveItem(at: backup, to: directory.appendingPathComponent(request.id.uuidString + "-attempt-" + UUID().uuidString))
            }
        }
        if fm.fileExists(atPath: done.path) { try finish(request, completed: done); return }
        let transaction: Transaction
        if fm.fileExists(atPath: journal.path) {
            transaction = try JSONDecoder().decode(Transaction.self, from: Data(contentsOf: journal))
            guard transaction.request == request else { throw Failure(message: "The saved move doesn’t match the pending request.") }
        } else {
            // Recover unsaved work at its original location before taking any copy.
            _ = try DraftRecovery(directory: support.appendingPathComponent("Recovery")).recover()
            guard !exists(target), source.resolvingSymlinksInPath() == source,
                  (try source.resourceValues(forKeys: [.isDirectoryKey])).isDirectory == true else {
                throw Failure(message: "The destination already exists or the original notebook is unavailable. No notebook was replaced.")
            }
            // External worktrees contain paths outside this folder and require a
            // Git-aware move. Ordinary repositories, including .git, stay intact.
            if exists(source.appendingPathComponent(".git")), (try source.appendingPathComponent(".git").resourceValues(forKeys: [.isDirectoryKey])).isDirectory != true {
                throw Failure(message: "Move this linked Git worktree with Git before changing its notebook location.")
            }
            try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            guard target.deletingLastPathComponent().resolvingSymlinksInPath() == target.deletingLastPathComponent() else {
                throw Failure(message: "Choose a destination outside linked folders. No files were moved.")
            }
            let identity = try fm.attributesOfItem(atPath: source.path)
            let device = (identity[.systemNumber] as! NSNumber).uint64Value
            guard device == (try fm.attributesOfItem(atPath: target.deletingLastPathComponent().path)[.systemNumber] as! NSNumber).uint64Value else {
                throw Failure(message: "This safe move requires both folders to be on the same disk. No files were moved.")
            }
            // A preparation interrupted before journal creation owns only this
            // UUID directory, never the original or the intended destination.
            if exists(backup) { try fm.removeItem(at: backup) }
            try fm.createDirectory(at: backup, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let manifest = try inventory(source)
            try fm.copyItem(at: source, to: backup.appendingPathComponent("Notebook"))
            guard try inventory(backup.appendingPathComponent("Notebook"), synchronize: true) == manifest, try inventory(source) == manifest else {
                throw Failure(message: "The notebook changed while preparing its backup. No files were moved. Try again after outside editing finishes.")
            }
            let edits = try plannedEdits(request)
            let preferences = try preferenceEdits(request)
            transaction = Transaction(request: request, device: device, inode: (identity[.systemFileNumber] as! NSNumber).uint64Value,
                                      manifest: manifest, edits: edits, preferences: preferences)
            try DraftRecovery.write(JSONEncoder().encode(transaction), to: journal)
            try syncDirectory(backup)
            try checkpoint?("prepared")
        }
        if exists(source) {
            guard !exists(target), try matches(source, transaction), try inventory(source) == transaction.manifest else {
                throw Failure(message: "The original notebook or destination changed after the backup. Nothing was overwritten. The pending move needs review.")
            }
            try checkEdits(transaction.edits, request: request, moved: false)
            try checkPreferences(transaction.preferences)
            // Atomic, same-volume rename preserves inodes, attachments, hidden
            // files and empty folders. RENAME_EXCL never replaces a destination.
            guard renamex_np(source.path, target.path, UInt32(RENAME_EXCL)) == 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            try syncDirectory(source.deletingLastPathComponent()); try syncDirectory(target.deletingLastPathComponent())
        } else {
            guard exists(target), try matches(target, transaction) else {
                throw Failure(message: "Couldn’t find the notebook from the interrupted move. Its verified backup is in \(backup.path).")
            }
        }
        try checkpoint?("moved")
        // Compare-and-write makes every step repeatable after a crash. Never
        // replace a file edited by another program since preparation.
        try checkEdits(transaction.edits, request: request, moved: true)
        try checkPreferences(transaction.preferences)
        for (index, edit) in transaction.edits.enumerated() {
            let file = URL(fileURLWithPath: edit.path)
            try checkEdits([edit], request: request, moved: true)
            if try Data(contentsOf: file) != edit.after { try DraftRecovery.write(edit.after, to: file) }
            try checkpoint?("edit-\(index)")
        }
        let historyFile = support.appendingPathComponent("Recovery/History/undo.sqlite")
        if exists(historyFile) {
            try UndoHistory(file: historyFile).relocate(source, to: target)
        }
        try checkpoint?("history")
        try checkPreferences(transaction.preferences)
        for edit in transaction.preferences {
            defaults.set(try PropertyListSerialization.propertyList(from: edit.after, format: nil), forKey: edit.path)
        }
        guard defaults.synchronize() else { throw Failure(message: "Couldn’t save the notebook’s new location. Restart Omega to finish the move.") }
        try checkpoint?("preferences")
        try finish(request, completed: done)
    }
    private func finish(_ request: Request, completed: URL) throws {
        try DraftRecovery.write(JSONEncoder().encode(request), to: completed)
        try fm.removeItem(at: pendingFile)
        try syncDirectory(directory)
    }
    private func exists(_ url: URL) -> Bool { (try? fm.attributesOfItem(atPath: url.path)) != nil }
    private func matches(_ url: URL, _ tx: Transaction) throws -> Bool {
        let attributes = try fm.attributesOfItem(atPath: url.path)
        return attributes[.type] as? FileAttributeType == .typeDirectory &&
            (attributes[.systemNumber] as? NSNumber)?.uint64Value == tx.device &&
            (attributes[.systemFileNumber] as? NSNumber)?.uint64Value == tx.inode
    }
    private func syncDirectory(_ url: URL) throws {
        let fd = open(url.path, O_RDONLY); guard fd >= 0 else { throw POSIXError(.EIO) }
        defer { close(fd) }
        guard fsync(fd) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    }
    private func inventory(_ root: URL, synchronize: Bool = false) throws -> [String: String] {
        var values: [String: String] = [:]
        func visit(_ folder: URL) throws {
            for entry in try fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey]) {
                // Foundation can enumerate /private/var through its /var alias.
                let file = folder.appendingPathComponent(entry.lastPathComponent)
                let info = try file.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey])
                let path = String(file.path.dropFirst(root.path.count + 1))
                if info.isSymbolicLink == true { throw Failure(message: "This notebook contains linked files. No files were moved; these links need review first.") }
                if info.isDirectory == true { values[path] = "directory"; try visit(file) }
                else if info.isRegularFile == true {
                    values[path] = SHA256.hash(data: try Data(contentsOf: file, options: .mappedIfSafe)).map { String(format: "%02x", $0) }.joined()
                    if synchronize { let handle = try FileHandle(forReadingFrom: file); defer { try? handle.close() }; try handle.synchronize() }
                } else { throw Failure(message: "The notebook contains a special file that cannot be safely moved.") }
            }
            if synchronize { try syncDirectory(folder) }
        }
        try visit(root); return values
    }
    private func mapped(_ value: String, _ request: Request) -> String {
        if value == request.source || value.hasPrefix(request.source + "/") { return request.destination + value.dropFirst(request.source.count) }
        if value.hasPrefix("file://"), let url = URL(string: value) {
            let path = mapped(url.path, request)
            if path != url.path { return URL(fileURLWithPath: path, isDirectory: value.hasSuffix("/")).absoluteString }
        }
        return value
    }
    private func mappedObject(_ object: Any, _ request: Request) -> Any {
        if let value = object as? String { return mapped(value, request) }
        if let values = object as? [Any] { return values.map { mappedObject($0, request) } }
        if let values = object as? [String: Any] { return Dictionary(values.map { (mapped($0.key, request), mappedObject($0.value, request)) }, uniquingKeysWith: { first, _ in first }) }
        return object
    }
    private func plannedEdits(_ request: Request) throws -> [Edit] {
        var edits: [Edit] = [], files = Set<URL>()
        let source = URL(fileURLWithPath: request.source), target = URL(fileURLWithPath: request.destination)
        for root in Set((defaults.stringArray(forKey: "notebooks") ?? []) + [source.path]) {
            let url = URL(fileURLWithPath: root)
            guard exists(url) else { continue }
            for entry in NoteFiles.flatten(try NoteFiles.scan(url)) where !entry.isFolder { files.insert(entry.url) }
        }
        for file in files.sorted(by: { $0.path < $1.path }) {
            let before = try Data(contentsOf: file), destination = URL(fileURLWithPath: mapped(file.path, request))
            guard let text = String(data: before, encoding: .utf8) else { throw Failure(message: "A note could not be read before moving. No files were moved.") }
            let after = Data(NoteFiles.rebaseLinks(text, from: file, to: destination, moving: source, to: target).utf8)
            if before != after { edits.append(Edit(path: destination.path, before: before, after: after)) }
        }
        var metadata = [support.appendingPathComponent("Recovery/Library/state.json"), support.appendingPathComponent("Git/notebooks.json"), support.appendingPathComponent("Collaboration/connections.json")]
        let deleted = support.appendingPathComponent("Recovery/History/Deleted Notes")
        if exists(deleted) {
            metadata += try fm.contentsOfDirectory(at: deleted, includingPropertiesForKeys: nil).map { $0.appendingPathComponent("record.json") }
        }
        for file in metadata where exists(file) {
            let before = try Data(contentsOf: file), object = try JSONSerialization.jsonObject(with: before)
            let after = try JSONSerialization.data(withJSONObject: mappedObject(object, request), options: [.sortedKeys])
            if try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) != after { edits.append(Edit(path: file.path, before: before, after: after)) }
        }
        return edits
    }
    private func preferenceEdits(_ request: Request) throws -> [Edit] {
        try ["notebooks", "lastFolder", "lastNote", "recentNotes", "notebookColors"].compactMap { key in
            guard let value = defaults.object(forKey: key) else { return nil }
            let before = try plist(value), after = try plist(mappedObject(value, request))
            return try samePreference(before, after) ? nil : Edit(path: key, before: before, after: after)
        }
    }
    private func plist(_ value: Any) throws -> Data { try PropertyListSerialization.data(fromPropertyList: value, format: .binary, options: 0) }
    private func samePreference(_ a: Data, _ b: Data) throws -> Bool {
        // Binary plist dictionary order is not stable across processes.
        let left = try PropertyListSerialization.propertyList(from: a, format: nil)
        let right = try PropertyListSerialization.propertyList(from: b, format: nil)
        return NSDictionary(dictionary: ["value": left]).isEqual(to: ["value": right])
    }
    private func checkPreferences(_ edits: [Edit]) throws {
        for edit in edits {
            guard let value = defaults.object(forKey: edit.path) else { throw Failure(message: "Notebook preferences changed during the move. The backup is safe.") }
            let data = try plist(value)
            guard try samePreference(data, edit.before) || samePreference(data, edit.after) else { throw Failure(message: "Notebook preferences changed during the move. The backup is safe.") }
        }
    }
    private func checkEdits(_ edits: [Edit], request: Request, moved: Bool) throws {
        for edit in edits {
            let path = !moved && (edit.path == request.destination || edit.path.hasPrefix(request.destination + "/")) ? request.source + edit.path.dropFirst(request.destination.count) : edit.path
            let current = try Data(contentsOf: URL(fileURLWithPath: path))
            guard current == edit.before || current == edit.after else { throw Failure(message: "A file changed during the notebook move: \(URL(fileURLWithPath: path).lastPathComponent). Both the file and migration backup are safe. Close outside editors before retrying.") }
        }
    }
}
