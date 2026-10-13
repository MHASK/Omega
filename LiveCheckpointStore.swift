import Foundation
import CryptoKit

struct LiveCheckpoint: Codable {
    var state: String
    var text: String
    var accepted: Bool
}

// Shared history travels in the same Git commit as the Markdown it projects.
// Compatible shared histories merge as CRDT updates; other conflicts are reviewed
// before the live files change.
enum LiveCheckpointStore {
    static func encode(_ value: LiveCheckpoint) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]; return try encoder.encode(value)
    }
    static let limit = 12 * 1024 * 1024
    static func file(root: URL, note: String) throws -> URL {
        guard !note.isEmpty, !note.split(separator: "/", omittingEmptySubsequences: false).contains(where: { $0.isEmpty || $0.hasPrefix(".") || $0.contains("\\") }) else { throw GitFailure("Invalid shared note path.") }
        let hash = SHA256.hash(data: Data(note.utf8)).map { String(format: "%02x", $0) }.joined()
        let file = root.appendingPathComponent(".omega/live/" + hash + ".json")
        try validate(file, root: root)
        return file
    }
    static func validate(_ file: URL, root: URL) throws {
        let base = root.standardizedFileURL.resolvingSymlinksInPath()
        for path in [root.appendingPathComponent(".omega"), file.deletingLastPathComponent(), file] {
            guard path.standardizedFileURL.resolvingSymlinksInPath().path.hasPrefix(base.path + "/") else { throw GitFailure("The shared history folder must stay inside its Git notebook.") }
            if let attributes = try? FileManager.default.attributesOfItem(atPath: path.path), attributes[.type] as? FileAttributeType == .typeSymbolicLink { throw GitFailure("Shared history cannot use symbolic links.") }
        }
    }
    static func read(_ file: URL) throws -> LiveCheckpoint? {
        guard FileManager.default.fileExists(atPath: file.path) else { return nil }
        let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
        guard attributes[.type] as? FileAttributeType == .typeRegular, (attributes[.size] as? NSNumber)?.intValue ?? limit + 1 <= limit else { throw GitFailure("The shared checkpoint is too large or invalid. Your Markdown is unchanged.") }
        return try JSONDecoder().decode(LiveCheckpoint.self, from: Data(contentsOf: file))
    }
    static func write(_ value: LiveCheckpoint, to file: URL, root: URL) throws {
        try validate(file, root: root)
        let data = try encode(value)
        guard data.count <= limit else { throw GitFailure("The shared checkpoint is too large. Your Markdown is safe on this Mac.") }
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: file, options: .atomic)
        let handle = try FileHandle(forWritingTo: file)
        defer { try? handle.close() }
        try handle.synchronize()
    }
}
