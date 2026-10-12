import Foundation
import AppKit
import SwiftUI

// Keep the palette and FNV-1a fallback in sync with Editor/task-labels.js.
enum LabelPastel: Int, CaseIterable, Identifiable {
    case lavender, mint, peach, sky, rose, butter, teal
    var id: Int { rawValue }
    var name: String { ["Lavender", "Mint", "Peach", "Sky", "Rose", "Butter", "Teal"][rawValue] }
    static func key(_ name: String) -> String { name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
    static func automatic(_ name: String) -> LabelPastel {
        var hash: UInt32 = 2166136261
        for scalar in key(name).unicodeScalars { hash = (hash ^ scalar.value) &* 16777619 }
        return LabelPastel(rawValue: Int(hash % 7))!
    }
    var ink: NSColor {
        let light: [UInt32] = [0x715891,0x457768,0x996841,0x4b7695,0x996177,0x84743b,0x527d81]
        let dark: [UInt32] = [0xcab5e1,0xafd0bf,0xdfb998,0xa9c9df,0xd8adc0,0xd2c28e,0xa8ced1]
        return NSColor(name: nil) { appearance in
            let rgb = appearance.bestMatch(from: [.darkAqua,.aqua]) == .darkAqua ? dark[rawValue] : light[rawValue]
            return NSColor(srgbRed: CGFloat((rgb >> 16) & 255)/255, green: CGFloat((rgb >> 8) & 255)/255, blue: CGFloat(rgb & 255)/255, alpha: 1)
        }
    }
}
struct ManagedTaskLabel: Identifiable {
    var id: String { LabelPastel.key(name) }
    let name: String
    var uses: Int
}
struct LabelPage {
    let file: URL
    let source: String
    var document: TaskDocument
}
enum TaskLabelCatalog {
    // Scan disk afresh, including archived work. Never follow symlinks or silently
    // skip an unreadable subtree during a library-wide label mutation.
    static func pages(in roots: [URL]) throws -> [LabelPage] {
        var seen = Set<String>(), result: [LabelPage] = []
        func scan(_ folder: URL) throws {
            let values = try folder.resourceValues(forKeys: [.isSymbolicLinkKey])
            guard values.isSymbolicLink != true, seen.insert(folder.resolvingSymlinksInPath().path).inserted else { return }
            let files = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.isDirectoryKey,.isSymbolicLinkKey,.isRegularFileKey,.fileSizeKey], options: [.skipsHiddenFiles])
            for entry in files.sorted(by: { $0.path < $1.path }) {
                let url = folder.appendingPathComponent(entry.lastPathComponent), values = try url.resourceValues(forKeys: [.isDirectoryKey,.isSymbolicLinkKey,.isRegularFileKey,.fileSizeKey])
                guard values.isSymbolicLink != true else { continue }
                if values.isDirectory == true { try scan(url); continue }
                guard values.isRegularFile == true, NoteFiles.extensions.contains(url.pathExtension.lowercased()), seen.insert(url.resolvingSymlinksInPath().path).inserted else { continue }
                let handle = try FileHandle(forReadingFrom: url)
                let prefix: Data
                do { prefix = try handle.read(upToCount: 64) ?? Data(); try handle.close() } catch { try? handle.close(); throw error }
                guard prefix.starts(with: Data(TaskDocument.marker.utf8)) else { continue }
                guard (values.fileSize ?? 0) <= 8_000_000 else { throw TaskPageError("‘\(url.lastPathComponent)’ is too large to update safely.") }
                let source = try String(contentsOf: url, encoding: .utf8)
                do { result.append(LabelPage(file: url, source: source, document: try TaskDocument(markdown: source))) }
                catch { throw TaskPageError("‘\(url.lastPathComponent)’ has task formatting Omega cannot safely edit. Check that page before managing labels.") }
            }
        }
        for root in roots { try scan(root) }
        return result
    }
    static func labels(in pages: [LabelPage]) -> [ManagedTaskLabel] {
        var labels: [String: ManagedTaskLabel] = [:]
        for page in pages { for item in page.document.references where item.kind != "goal" {
            var seen = Set<String>()
            for name in item.details.labels ?? [] {
                let key = LabelPastel.key(name); guard seen.insert(key).inserted else { continue }
                if labels[key] != nil { labels[key]!.uses += 1 } else { labels[key] = ManagedTaskLabel(name: name, uses: 1) }
            }
        } }
        return labels.values.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
    static func validateName(_ raw: String) throws -> String {
        let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.utf16.count <= 40, !name.contains(where: { $0.isNewline || $0 == "\0" }) else { throw TaskPageError("Use a label name of 1–40 characters on one line.") }
        return name
    }
}
extension TaskDocument {
    @discardableResult mutating func replaceLabel(_ old: String, with name: String?) -> Int {
        let key = LabelPastel.key(old); var count = 0
        func update(_ details: inout TaskDetails) {
            guard let labels = details.labels, labels.contains(where: { LabelPastel.key($0) == key }) else { return }
            count += 1; var seen = Set<String>()
            let next = labels.compactMap { LabelPastel.key($0) == key ? name : $0 }.filter { seen.insert(LabelPastel.key($0)).inserted }
            details.labels = next.isEmpty ? nil : next
        }
        func children(_ items: inout [TaskCheckItem]) { for index in items.indices { update(&items[index].details); children(&items[index].subtasks) } }
        for index in tasks.indices { update(&tasks[index].details); children(&tasks[index].subtasks) }
        return count
    }
}
@MainActor extension Notebook {
    func labelPastel(_ name: String) -> LabelPastel { labelColors[LabelPastel.key(name)].flatMap(LabelPastel.init(rawValue:)) ?? .automatic(name) }
    func saveLabelColors(_ colors: [String: Int]) throws {
        guard colors.allSatisfy({ LabelPastel(rawValue: $0.value) != nil }) else { throw TaskPageError("Choose one of Omega’s pastel colors.") }
        let folder = recovery.directory.appendingPathComponent("Settings")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try DraftRecovery.write(JSONEncoder().encode(colors), to: folder.appendingPathComponent("labels.json"))
        labelColors = colors
    }
    func setLabelColor(_ name: String, _ color: LabelPastel) throws {
        var colors = labelColors; colors[LabelPastel.key(name)] = color.rawValue; try saveLabelColors(colors)
    }
    func changeLabel(_ label: String, to raw: String?, completion: @escaping (String?) -> Void) {
        let perform = {
            do {
                try self.prepareAssistantAccess()
                let next = try raw.map(TaskLabelCatalog.validateName)
                let pages = try TaskLabelCatalog.pages(in: self.roots)
                if let next, LabelPastel.key(label) != LabelPastel.key(next), TaskLabelCatalog.labels(in: pages).contains(where: { $0.id == LabelPastel.key(next) }) {
                    throw TaskPageError("A label named ‘\(next.uppercased())’ already exists. Choose another name.")
                }
                let changes: [(URL, String, String)] = pages.compactMap { page in
                    var document = page.document
                    guard document.replaceLabel(label, with: next) > 0, document.markdown != page.source else { return nil }
                    return (page.file, page.source, document.markdown)
                }
                // Establish the new color before changing files, so even an interrupted
                // multi-page rename has the same appearance under both names.
                if let next { try self.setLabelColor(next, self.labelPastel(label)) }
                let service = AssistantService(self, history: self.recovery.directory.appendingPathComponent("History/Label Changes"))
                @MainActor func apply(_ index: Int) {
                    guard index < changes.count else {
                        do {
                            if next == nil || LabelPastel.key(next!) != LabelPastel.key(label) {
                                var colors = self.labelColors; colors.removeValue(forKey: LabelPastel.key(label)); try self.saveLabelColors(colors)
                            }
                            self.status = "All changes saved"; completion(nil)
                        } catch { completion("Labels updated, but the color preference could not be saved: \(error.localizedDescription)") }
                        return
                    }
                    let (file, before, after) = changes[index]
                    let finish: ([String: Any]) -> Void = { response in
                        guard response["isError"] as? Bool != true else {
                            let reason = (response["content"] as? [[String: Any]])?.first?["text"] as? String ?? "This page changed."
                            completion("\(index) of \(changes.count) pages updated. \(reason) Refresh labels and try again; previous versions are kept in history."); return
                        }
                        apply(index + 1)
                    }
                    do { try service.update(["path": file.path, "expected_revision": AssistantWire.hash(before), "markdown": after], completion: finish) }
                    catch { finish(FolioMCP.failure(error.localizedDescription)) }
                }
                apply(0)
            } catch { completion(error.localizedDescription) }
        }
        if let editor = richEditor { editor.synchronize { success in if success { perform() } else { completion("Could not save the current editor. No labels were changed.") } } }
        else { perform() }
    }
}
