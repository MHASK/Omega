import Foundation
import CryptoKit

// A write-ahead draft survives termination before the normal autosave fires.
// Never replace a file that has diverged from the draft's original contents.
final class DraftRecovery {
    struct Draft: Codable {
        let path: String
        let original: String
        let text: String
    }
    let directory: URL
    init(directory: URL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Folio/Recovery")) {
        self.directory = directory
    }
    private func recordURL(_ file: URL) -> URL {
        let key = SHA256.hash(data: Data(file.standardizedFileURL.path.utf8)).map { String(format: "%02x", $0) }.joined()
        return directory.appendingPathComponent(key + ".json")
    }
    static func write(_ data: Data, to file: URL) throws {
        try data.write(to: file, options: .atomic)
        let handle = try FileHandle(forWritingTo: file)
        defer { try? handle.close() }
        try handle.synchronize()
    }
    static func write(_ text: String, to file: URL) throws { try write(Data(text.utf8), to: file) }
    func checkpoint(_ text: String, original: String, file: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Self.write(JSONEncoder().encode(Draft(path: file.path, original: original, text: text)), to: recordURL(file))
    }
    func clear(_ file: URL) { try? FileManager.default.removeItem(at: recordURL(file)) }

    @discardableResult func recover() throws -> [URL] {
        guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
        let records = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).filter { $0.pathExtension == "json" }
        var recovered: [URL] = []
        var firstError: Error?
        for record in records {
            do {
                let draft = try JSONDecoder().decode(Draft.self, from: Data(contentsOf: record))
                let file = URL(fileURLWithPath: draft.path)
                let current = try? String(contentsOf: file, encoding: .utf8)
                if current == draft.text { try FileManager.default.removeItem(at: record); continue }
                if current == draft.original {
                    try Self.write(draft.text, to: file)
                    recovered.append(file)
                } else {
                    var parent = file.deletingLastPathComponent()
                    if !FileManager.default.isWritableFile(atPath: parent.path) {
                        parent = directory.appendingPathComponent("Recovered Notes")
                        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
                    }
                    let copy = NoteFiles.uniqueURL(in: parent, name: file.deletingPathExtension().lastPathComponent + " (recovered)", ext: file.pathExtension.isEmpty ? "md" : file.pathExtension)
                    try Self.write(draft.text, to: copy)
                    recovered.append(copy)
                }
                try FileManager.default.removeItem(at: record)
            } catch { if firstError == nil { firstError = error } }
        }
        if let firstError { throw firstError } // Keep failed records for another attempt.
        return recovered
    }
}
