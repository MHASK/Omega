import Foundation
import SQLite3

// Markdown remains the source of truth. This local journal stores reversible
// UTF-8 splices, with no age/count pruning. SQLite commits each edit durably.
final class UndoHistory {
    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }
    struct Change: Codable {
        let offset: Int
        let removed: Data
        let inserted: Data
        init(_ before: Data, _ after: Data) {
            let a = [UInt8](before), b = [UInt8](after)
            var start = 0, end = 0
            while start < min(a.count, b.count), a[start] == b[start] { start += 1 }
            while end < min(a.count, b.count) - start, a[a.count - end - 1] == b[b.count - end - 1] { end += 1 }
            offset = start; removed = Data(a[start..<(a.count - end)]); inserted = Data(b[start..<(b.count - end)])
        }
        func applying(to input: Data, reverse: Bool) throws -> Data {
            let old = reverse ? inserted : removed, new = reverse ? removed : inserted
            guard offset >= 0, offset + old.count <= input.count,
                  input.subdata(in: offset..<(offset + old.count)) == old else {
                throw Failure(message: "Undo history does not match this note. Your note was left unchanged.")
            }
            var result = input; result.replaceSubrange(offset..<(offset + old.count), with: new)
            return result
        }
        var smallTyping: Bool {
            (removed.isEmpty != inserted.isEmpty) && max(removed.count, inserted.count) <= 16
                && !removed.contains(10) && !inserted.contains(10)
        }
        func follows(_ previous: Change) -> Bool {
            guard smallTyping, previous.smallTyping else { return false }
            if removed.isEmpty, previous.removed.isEmpty { return offset == previous.offset + previous.inserted.count }
            if inserted.isEmpty, previous.inserted.isEmpty { return offset == previous.offset || offset + removed.count == previous.offset }
            return false
        }
    }
    struct Revision: Codable {
        let parent: Int64
        let group: String
        let delta: Change
        let beforeSelection: String
        let afterSelection: String
    }
    struct State: Codable {
        var content: Data
        var head: Int64 = 0
        var redo: [[Int64]] = []
    }
    struct Travel {
        let text: String
        let selection: String
    }
    let file: URL
    private var db: OpaquePointer?
    private var last: (path: String, head: Int64, time: TimeInterval, delta: Change, group: String)?
    init(file: URL) { self.file = file }
    deinit { if let db { sqlite3_close(db) } }
    func breakGroup() { last = nil }
    private func open() throws {
        if db != nil { return }
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard sqlite3_open_v2(file.path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else {
            if let db { sqlite3_close(db) }; db = nil
            throw Failure(message: "Couldn’t open local undo history.")
        }
        do {
            sqlite3_busy_timeout(db, 1500)
            try execute("PRAGMA journal_mode=WAL")
            try execute("PRAGMA synchronous=FULL")
            try execute("PRAGMA fullfsync=ON")
            try execute("PRAGMA checkpoint_fullfsync=ON")
            try execute("CREATE TABLE IF NOT EXISTS notes(path TEXT PRIMARY KEY, state BLOB NOT NULL)")
            try execute("CREATE TABLE IF NOT EXISTS revisions(id INTEGER PRIMARY KEY AUTOINCREMENT, value BLOB NOT NULL)")
        } catch { sqlite3_close(db); db = nil; throw error }
    }
    private func failure() -> Failure { Failure(message: "Couldn’t save undo history: " + String(cString: sqlite3_errmsg(db))) }
    @discardableResult private func query(_ sql: String, _ arguments: [Data] = [], _ row: ((OpaquePointer) throws -> Void)? = nil) throws -> Int64 {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else { throw failure() }
        defer { sqlite3_finalize(statement) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for (i, data) in arguments.enumerated() {
            let result = data.withUnsafeBytes { sqlite3_bind_blob(statement, Int32(i + 1), $0.baseAddress, Int32(data.count), transient) }
            guard result == SQLITE_OK else { throw failure() }
        }
        var result = sqlite3_step(statement)
        while result == SQLITE_ROW { try row?(statement); result = sqlite3_step(statement) }
        guard result == SQLITE_DONE else { throw failure() }
        return sqlite3_last_insert_rowid(db)
    }
    private func execute(_ sql: String) throws { try query(sql) }
    private func bytes(_ row: OpaquePointer, _ column: Int32 = 0) -> Data {
        let count = Int(sqlite3_column_bytes(row, column))
        guard count > 0, let pointer = sqlite3_column_blob(row, column) else { return Data() }
        return Data(bytes: pointer, count: count)
    }
    private func transaction<T>(_ work: () throws -> T) throws -> T {
        try open(); try execute("BEGIN IMMEDIATE")
        do { let result = try work(); try execute("COMMIT"); return result }
        catch { try? execute("ROLLBACK"); throw error }
    }
    private func state(_ path: String) throws -> State? {
        var result: State?
        try query("SELECT state FROM notes WHERE path=CAST(? AS TEXT)", [Data(path.utf8)]) { result = try JSONDecoder().decode(State.self, from: self.bytes($0)) }
        return result
    }
    private func put(_ state: State, _ path: String) throws {
        try query("INSERT INTO notes(path,state) VALUES(CAST(? AS TEXT),?) ON CONFLICT(path) DO UPDATE SET state=excluded.state", [Data(path.utf8), try JSONEncoder().encode(state)])
    }
    private func revision(_ id: Int64) throws -> Revision {
        var result: Revision?
        try query("SELECT value FROM revisions WHERE id=\(id)") { result = try JSONDecoder().decode(Revision.self, from: self.bytes($0)) }
        guard let result else { throw Failure(message: "An undo history entry is unavailable. Your note was left unchanged.") }
        return result
    }
    private func append(_ value: Data, to state: inout State, group: String, before: String = "", after: String = "") throws {
        let revision = Revision(parent: state.head, group: group, delta: Change(state.content, value), beforeSelection: before, afterSelection: after)
        state.head = try query("INSERT INTO revisions(value) VALUES(?)", [try JSONEncoder().encode(revision)])
        state.content = value; state.redo = []
    }
    // Outside edits become a separate undoable step. Never replay stale history
    // over a differing file, including recovery after an interrupted commit.
    func observe(_ text: String, at url: URL) throws {
        breakGroup()
        try transaction {
            let path = url.standardizedFileURL.path, content = Data(text.utf8)
            var item = try state(path) ?? State(content: content)
            if item.content != content { try append(content, to: &item, group: UUID().uuidString) }
            try put(item, path)
        }
    }
    func record(before: String, after: String, at url: URL, beforeSelection: String = "", afterSelection: String = "", typing: Bool = false, now: TimeInterval = Date.timeIntervalSinceReferenceDate) throws {
        guard before != after else { return }
        try transaction {
            let path = url.standardizedFileURL.path, old = Data(before.utf8), new = Data(after.utf8)
            var item = try state(path) ?? State(content: old)
            if item.content != old { try append(old, to: &item, group: UUID().uuidString); last = nil }
            let delta = Change(old, new)
            let grouped = typing && last.map { $0.path == path && $0.head == item.head && now - $0.time < 0.65 && delta.follows($0.delta) } == true
            let group = grouped ? last!.group : UUID().uuidString
            try append(new, to: &item, group: group, before: beforeSelection, after: afterSelection)
            try put(item, path)
            last = typing ? (path, item.head, now, delta, group) : nil
        }
    }
    // The recovery draft is durable BEFORE advancing the history cursor. An
    // interrupted undo is recovered just like an interrupted ordinary edit.
    func travel(at url: URL, expected: String, redo: Bool, protect: (String) throws -> Void) throws -> Travel? {
        breakGroup()
        return try transaction {
            let path = url.standardizedFileURL.path
            guard var item = try state(path) else { return nil }
            guard item.content == Data(expected.utf8) else { throw Failure(message: "This note changed. Reopen it before using undo.") }
            var selection = ""
            if redo {
                guard let ids = item.redo.popLast() else { return nil }
                for id in ids.reversed() {
                    let step = try revision(id)
                    guard step.parent == item.head else { throw Failure(message: "Redo history does not match this note.") }
                    item.content = try step.delta.applying(to: item.content, reverse: false)
                    item.head = id; selection = step.afterSelection
                }
            } else {
                guard item.head != 0 else { return nil }
                let group = try revision(item.head).group
                var ids: [Int64] = []
                while item.head != 0 {
                    let step = try revision(item.head)
                    if step.group != group { break }
                    ids.append(item.head); item.content = try step.delta.applying(to: item.content, reverse: true)
                    item.head = step.parent; selection = step.beforeSelection
                }
                item.redo.append(ids)
            }
            guard let text = String(data: item.content, encoding: .utf8) else { throw Failure(message: "Undo history contains invalid text. Your note was left unchanged.") }
            try protect(text)
            try put(item, path)
            return Travel(text: text, selection: selection)
        }
    }
    func relocate(_ original: URL, to target: URL) throws {
        breakGroup()
        try transaction {
            var paths: [String] = []
            try query("SELECT path FROM notes") { paths.append(String(decoding: self.bytes($0), as: UTF8.self)) }
            for path in paths where path == original.path || path.hasPrefix(original.path + "/") {
                let new = target.path + path.dropFirst(original.path.count)
                // Preserve an old history at a reused destination too.
                if try state(new) != nil {
                    try query("UPDATE notes SET path=CAST(? AS TEXT) WHERE path=CAST(? AS TEXT)", [Data((new + ".history-" + UUID().uuidString).utf8), Data(new.utf8)])
                }
                try query("UPDATE notes SET path=CAST(? AS TEXT) WHERE path=CAST(? AS TEXT)", [Data(new.utf8), Data(path.utf8)])
            }
        }
    }
}

// Keep an app-managed recovery copy as well as macOS Trash. Restoring never
// replaces a same-named file and works after a relaunch or emptying the Trash.
final class DeletedNotes {
    struct Entry: Codable {
        let original: URL
        let backup: URL
        let date: Date
        var completed = false
        var restored = false
    }
    let directory: URL
    init(directory: URL) { self.directory = directory }
    private func metadata(_ entry: Entry) -> URL { entry.backup.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("record.json") }
    func prepare(_ url: URL) throws -> Entry {
        let container = directory.appendingPathComponent(UUID().uuidString)
        let payload = container.appendingPathComponent("files")
        try FileManager.default.createDirectory(at: payload, withIntermediateDirectories: true)
        let entry = Entry(original: url, backup: payload.appendingPathComponent(url.lastPathComponent), date: Date())
        try FileManager.default.copyItem(at: url, to: entry.backup)
        try DraftRecovery.write(JSONEncoder().encode(entry), to: metadata(entry))
        return entry
    }
    func complete(_ entry: Entry) throws {
        var completed = entry; completed.completed = true
        try DraftRecovery.write(JSONEncoder().encode(completed), to: metadata(entry))
    }
    func latest() throws -> Entry? {
        guard FileManager.default.fileExists(atPath: directory.path) else { return nil }
        return try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .compactMap { try? JSONDecoder().decode(Entry.self, from: Data(contentsOf: $0.appendingPathComponent("record.json"))) }
            .filter { !$0.restored && ($0.completed || !FileManager.default.fileExists(atPath: $0.original.path)) && FileManager.default.fileExists(atPath: $0.backup.path) }
            .sorted { $0.date > $1.date }.first
    }
    func restore(_ entry: Entry) throws -> URL {
        let manager = FileManager.default, parent = entry.original.deletingLastPathComponent()
        try manager.createDirectory(at: parent, withIntermediateDirectories: true)
        var target = entry.original, count = 1
        while manager.fileExists(atPath: target.path) {
            let suffix = count == 1 ? " (restored)" : " (restored \(count))"
            target = parent.appendingPathComponent(entry.original.deletingPathExtension().lastPathComponent + suffix)
            if !entry.original.pathExtension.isEmpty { target.appendPathExtension(entry.original.pathExtension) }
            count += 1
        }
        try manager.copyItem(at: entry.backup, to: target)
        var restored = entry; restored.restored = true
        try DraftRecovery.write(JSONEncoder().encode(restored), to: metadata(entry))
        return target
    }
}
