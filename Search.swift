import Foundation
import AppKit
import SwiftUI

struct NoteSearchAnchor: Codable, Equatable {
    let term: String
    let location: Int
    let length: Int
    let before: [String]
    let after: [String]
}

struct SearchReveal {
    let id = UUID()
    let url: URL
    let anchor: NoteSearchAnchor
}

struct NoteSearchResult: Identifiable {
    let url: URL
    let root: URL
    let title: String
    let location: String
    let snippet: String
    let terms: Set<String>
    let score: Double
    let anchor: NoteSearchAnchor?
    var id: String { url.path }
}

// A disposable, in-memory passage index. It reads only the open notebooks and never
// writes to notes. All indexing and ranking runs on SearchModel's serial worker.
final class NoteSearchIndex {
    struct Passage {
        let text: String
        let counts: [String: Int]
        let length: Int
        let sourceRange: NSRange
    }
    struct Document {
        let url: URL
        let root: URL
        let modified: Date
        let signature: String
        let title: String
        let source: String
        let location: String
        let titleWords: Set<String>
        let pathWords: Set<String>
        let headingWords: Set<String>
        let passages: [Passage]
    }
    private(set) var documents: [URL: Document] = [:]
    private var postings: [String: [URL: [Int: Int]]] = [:]
    private var vocabulary: [String] = []
    private var averageLength = 1.0
    private var passageCount = 0
    private(set) var skipped = 0
    private(set) var reads = 0
    private static let stopWords = Set("a an the and or but for of to in on at by with from is are was were be been being do does did have has had i me my we our you your it its this that these those what which when where who why how can could would should please find show about".split(separator: " ").map(String.init))

    static func folded(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: Locale(identifier: "en_US_POSIX")).lowercased()
    }
    static func words(_ text: String) -> [String] {
        folded(text).split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
    }
    static func clean(_ markdown: String) -> String {
        let blockless = markdown
            .replacingOccurrences(of: #"(?m)^\s*\|?\s*:?-{3,}:?\s*(?:\|\s*:?-{3,}:?\s*)+\|?\s*$"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"(?m)^\s*(?:`{3,}|~{3,})[^\n]*$|^\s*(?:[-*_]\s*){3,}$"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"(?m)^\s*(?:#{1,6}\s+|>\s*|(?:[-*+]|\d+[.)])\s+(?:\[[ xX]\]\s*)?)"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"<!--[\s\S]*?-->|</?[A-Za-z][^>]*>"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"(?m)^\s*\[[^\]]+\]:[^\n]*$"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"\[([^\]]+)\]\[[^\]]*\]"#, with: "$1", options: .regularExpression)
        // Foundation's local CommonMark parser removes inline syntax while preserving
        // literal code, escaped punctuation, link labels, image alt text, and entities.
        let inline = (try? AttributedString(markdown: blockless, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))).map { String($0.characters) } ?? blockless
        return inline.replacingOccurrences(of: #"(?m)^\s*\||\|\s*$"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"\s*\|\s*"#, with: " · ", options: .regularExpression)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
    static func passages(_ text: String) -> [Passage] {
        var chunks: [(String, NSRange)] = [], current = "", currentStart = 0, currentEnd = 0, offset = 0
        func flush() {
            if !current.isEmpty { chunks.append((current, NSRange(location: currentStart, length: currentEnd - currentStart))); current = "" }
        }
        for paragraph in text.components(separatedBy: "\n\n") {
            let length = (paragraph as NSString).length
            defer { offset += length + 2 }
            let plain = clean(paragraph)
            if plain.isEmpty { continue }
            if current.count + plain.count > 900 { flush() }
            if plain.count > 1200 {
                flush()
                let raw = paragraph as NSString
                var start = 0
                while start < raw.length {
                    let range = raw.rangeOfComposedCharacterSequences(for: NSRange(location: start, length: min(1200, raw.length - start)))
                    chunks.append((clean(raw.substring(with: range)), NSRange(location: offset + range.location, length: range.length)))
                    if NSMaxRange(range) == raw.length { break }
                    start = NSMaxRange(range) - 160
                }
            } else {
                if current.isEmpty { currentStart = offset }
                current += (current.isEmpty ? "" : " ") + plain; currentEnd = offset + length
            }
        }
        flush()
        if chunks.isEmpty { chunks = [("", NSRange(location: 0, length: 0))] }
        return chunks.map {
            let tokens = words($0.0)
            return Passage(text: $0.0, counts: Dictionary(tokens.map { ($0, 1) }, uniquingKeysWith: +), length: max(1, tokens.count), sourceRange: $0.1)
        }
    }

    func refresh(roots: [URL], draft: (URL, String)? = nil, excluding archived: Set<String> = []) {
        var files: [String: (url: URL, root: URL)] = [:]
        for root in roots.sorted(by: { $0.path.count < $1.path.count }) {
            let canonicalRoot = root.resolvingSymlinksInPath().path
            for entry in NoteFiles.flatten((try? NoteFiles.scan(root)) ?? []) where !entry.isFolder {
                if archived.contains(where: { entry.url.path == $0 || entry.url.path.hasPrefix($0 + "/") }) { continue }
                let canonical = entry.url.resolvingSymlinksInPath().path
                guard canonical.hasPrefix(canonicalRoot + "/") else { continue }
                // Keep the user's root spelling (e.g. /var rather than /private/var),
                // while deduplicating overlapping notebooks by the actual file path.
                let relative = String(canonical.dropFirst(canonicalRoot.count + 1))
                files[canonical] = (root.appendingPathComponent(relative), root)
            }
        }
        let currentURLs = Set(files.values.map(\.url))
        var changed = false
        skipped = 0
        for old in documents.keys where !currentURLs.contains(old) { documents.removeValue(forKey: old); changed = true }
        for (url, root) in files.values {
            do {
                let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
                let modified = attrs[.modificationDate] as? Date ?? .distantPast
                let size = (attrs[.size] as? NSNumber)?.intValue ?? 0
                guard size <= 8_000_000 else { throw CocoaError(.fileReadTooLarge) }
                let override = draft?.0 == url ? draft?.1 : nil
                let signature = "\(modified.timeIntervalSinceReferenceDate)|\(size)|\(attrs[.systemFileNumber] ?? 0)|\(override?.hashValue ?? 0)"
                if documents[url]?.signature == signature && documents[url]?.root == root { continue }
                let text = try override ?? String(contentsOf: url, encoding: .utf8)
                reads += 1
                let title = url.deletingPathExtension().lastPathComponent
                let parent = url.deletingLastPathComponent().path
                let relative = parent == root.path ? "" : String(parent.dropFirst(root.path.count + 1))
                let location = root.lastPathComponent + (relative.isEmpty ? "" : " / " + relative.replacingOccurrences(of: "/", with: " / "))
                let headings = text.components(separatedBy: "\n").filter { $0.hasPrefix("#") }.joined(separator: " ")
                documents[url] = Document(url: url, root: root, modified: modified, signature: signature, title: title, source: text, location: location, titleWords: Set(Self.words(title)), pathWords: Set(Self.words(location)), headingWords: Set(Self.words(headings)), passages: Self.passages(text))
                changed = true
            } catch {
                if documents.removeValue(forKey: url) != nil { changed = true }
                skipped += 1
            }
        }
        if changed { rebuildPostings() }
    }

    private func rebuildPostings() {
        postings = [:]; passageCount = 0
        var length = 0
        for doc in documents.values {
            for (index, passage) in doc.passages.enumerated() {
                passageCount += 1; length += passage.length
                for (term, count) in passage.counts { postings[term, default: [:]][doc.url, default: [:]][index] = count }
            }
            for term in doc.titleWords.union(doc.pathWords).union(doc.headingWords) {
                // -1 is metadata, never a body passage.
                postings[term, default: [:]][doc.url, default: [:]][-1] = 1
            }
        }
        averageLength = Double(max(1, length)) / Double(max(1, passageCount))
        vocabulary = postings.keys.sorted()
    }

    static func oneEditApart(_ a: String, _ b: String) -> Bool {
        let a = Array(a), b = Array(b)
        guard abs(a.count - b.count) <= 1 else { return false }
        if a.count == b.count {
            let mismatches = a.indices.filter { a[$0] != b[$0] }
            if mismatches.count <= 1 { return true }
            if mismatches.count == 2, mismatches[1] == mismatches[0] + 1 {
                let i = mismatches[0], j = mismatches[1]
                return a[i] == b[j] && a[j] == b[i]
            }
            return false
        }
        let shorter = a.count < b.count ? a : b, longer = a.count < b.count ? b : a
        var i = 0, j = 0, missed = false
        while i < shorter.count && j < longer.count {
            if shorter[i] == longer[j] { i += 1; j += 1 }
            else if missed { return false }
            else { missed = true; j += 1 }
        }
        return true
    }

    func search(_ query: String, recent: [String] = [], limit: Int = 30) -> [NoteSearchResult] {
        let raw = Self.words(query)
        if query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return documents.values.sorted { a, b in
                let ai = recent.firstIndex(of: a.url.path) ?? Int.max, bi = recent.firstIndex(of: b.url.path) ?? Int.max
                if ai != bi { return ai < bi }
                if a.modified != b.modified { return a.modified > b.modified }
                return a.url.path < b.url.path
            }.prefix(limit).map { result($0, passage: 0, terms: [], score: 0) }
        }
        guard !raw.isEmpty else { return [] }
        let useful = raw.filter { !Self.stopWords.contains($0) }
        let terms = Array(Set(useful.isEmpty ? raw : useful)).sorted().prefix(24)
        var scores: [URL: [Int: Double]] = [:]
        var metadataScores: [URL: Double] = [:]
        var coverage: [URL: Set<String>] = [:]
        var matchedWords: [URL: Set<String>] = [:]
        for term in terms {
            var expansions: [(String, Double)] = postings[term] == nil ? [] : [(term, 1)]
            // Prefix completion is limited to the word currently being typed.
            if term == raw.last && term.count >= 2 {
                expansions += vocabulary.lazy.filter { $0 != term && $0.hasPrefix(term) }.prefix(40).map { ($0, 0.68) }
            }
            if expansions.isEmpty && term.count >= 4 {
                expansions = vocabulary.lazy.filter { abs($0.count - term.count) <= 1 && Self.oneEditApart(term, $0) }.prefix(12).map { ($0, 0.45) }
            }
            for (word, weight) in expansions {
                guard let matches = postings[word] else { continue }
                let frequency = matches.values.reduce(0) { $0 + $1.keys.filter { $0 >= 0 }.count }
                let idf = log(1 + (Double(max(passageCount, frequency) - frequency) + 0.5) / (Double(frequency) + 0.5))
                for (url, counts) in matches {
                    guard let doc = documents[url] else { continue }
                    coverage[url, default: []].insert(term); matchedWords[url, default: []].insert(word)
                    var boost = 0.0
                    if doc.titleWords.contains(word) { boost += 7 }
                    if doc.headingWords.contains(word) { boost += 3 }
                    if doc.pathWords.contains(word) { boost += 0.8 }
                    metadataScores[url, default: 0] += boost * weight
                    for (index, count) in counts where index >= 0 {
                        let tf = Double(count), length = Double(doc.passages[index].length)
                        let bm25 = idf * (tf * 2.2) / (tf + 1.2 * (0.25 + 0.75 * length / averageLength))
                        scores[url, default: [:]][index, default: 0] += bm25 * weight
                    }
                }
            }
        }
        let phrase = Self.folded(query).trimmingCharacters(in: .whitespacesAndNewlines)
        var ranked: [(doc: Document, passage: Int, terms: Set<String>, score: Double)] = []
        for (url, found) in coverage {
            guard let doc = documents[url] else { continue }
            let best = (scores[url] ?? [:]).max { a, b in a.value == b.value ? a.key > b.key : a.value < b.value }
            var score = (best?.value ?? 0) + (metadataScores[url] ?? 0)
            let fraction = Double(found.count) / Double(terms.count)
            score *= fraction * fraction
            if found.count == terms.count { score += 5 }
            if Self.folded(doc.title) == phrase { score += 20 }
            else if Self.folded(doc.title).contains(phrase) { score += 8 }
            if let best, Self.folded(doc.passages[best.key].text).contains(phrase) { score += 3 }
            ranked.append((doc, best?.key ?? 0, matchedWords[url] ?? [], score))
        }
        return ranked.sorted { a, b in a.score == b.score ? a.doc.url.path < b.doc.url.path : a.score > b.score }.prefix(limit).map {
            result($0.doc, passage: $0.passage, terms: $0.terms, score: $0.score)
        }
    }

    static func bestMatch(_ text: String, terms: Set<String>) -> NSTextCheckingResult? {
        let regex = try! NSRegularExpression(pattern: #"[\p{L}\p{M}\p{N}]+"#)
        let ns = text as NSString
        let hits = regex.matches(in: text, range: NSRange(location: 0, length: ns.length)).filter {
            terms.contains(folded(ns.substring(with: $0.range)))
        }
        // Center the excerpt on the densest cluster of query words, not the start of
        // a paragraph. Keep it short enough that the match stays visible in one row.
        return hits.enumerated().max { a, b in
            func count(_ hit: NSTextCheckingResult) -> Int {
                Set(hits.filter { abs($0.range.location - hit.range.location) < 55 }.map { folded(ns.substring(with: $0.range)) }).count
            }
            let ac = count(a.element), bc = count(b.element)
            return ac == bc ? a.offset > b.offset : ac < bc
        }?.element
    }
    static func excerpt(_ text: String, terms: Set<String>) -> String {
        guard !text.isEmpty else { return "" }
        let ns = text as NSString
        let best = bestMatch(text, terms: terms)
        let chars = Array(text)
        let anchor = best.flatMap { Range($0.range, in: text) }.map { text.distance(from: text.startIndex, to: $0.lowerBound) } ?? 0
        var start = max(0, anchor - 18)
        if start > 0 { while start < anchor && !chars[start - 1].isWhitespace { start += 1 } }
        let matchLength = best.map { ns.substring(with: $0.range).count } ?? 0
        var end = min(chars.count, max(start + 72, anchor + matchLength + 20))
        if end < chars.count {
            var boundary = end
            while boundary > anchor + matchLength && !chars[boundary - 1].isWhitespace { boundary -= 1 }
            if boundary > start + 24 { end = boundary }
        }
        let excerpt = String(chars[start..<max(start, end)]).trimmingCharacters(in: .whitespacesAndNewlines)
        return (start > 0 ? "… " : "") + excerpt + (end < chars.count ? " …" : "")
    }
    private func sourceAnchor(_ doc: Document, passage: Passage, terms: Set<String>) -> NoteSearchAnchor? {
        guard let match = Self.bestMatch(passage.text, terms: terms) else { return nil }
        let plain = passage.text as NSString, raw = doc.source as NSString
        let term = Self.folded(plain.substring(with: match.range))
        let before = Array(Self.words(plain.substring(to: match.range.location)).suffix(4))
        let after = Array(Self.words(plain.substring(from: NSMaxRange(match.range))).prefix(4))
        let regex = try! NSRegularExpression(pattern: #"[\p{L}\p{M}\p{N}]+"#)
        let tokens = regex.matches(in: doc.source, range: passage.sourceRange)
        let expected = Double(passage.sourceRange.location) + Double(passage.sourceRange.length) * Double(match.range.location) / Double(max(1, plain.length))
        let candidates = tokens.enumerated().filter { Self.folded(raw.substring(with: $0.element.range)) == term }
        func score(_ index: Int) -> Double {
            let previous = tokens[max(0, index - 4)..<index].map { Self.folded(raw.substring(with: $0.range)) }
            let following = tokens[(index + 1)..<min(tokens.count, index + 5)].map { Self.folded(raw.substring(with: $0.range)) }
            let context = zip(before.reversed(), previous.reversed()).filter { $0 == $1 }.count + zip(after, following).filter { $0 == $1 }.count
            return Double(context) * 1000 - abs(Double(tokens[index].range.location) - expected) / Double(max(1, passage.sourceRange.length))
        }
        guard let chosen = candidates.max(by: { score($0.offset) < score($1.offset) })?.element else { return nil }
        return NoteSearchAnchor(term: term, location: chosen.range.location, length: chosen.range.length, before: before, after: after)
    }
    private func result(_ doc: Document, passage: Int, terms: Set<String>, score: Double) -> NoteSearchResult {
        let passage = doc.passages[passage]
        return NoteSearchResult(url: doc.url, root: doc.root, title: doc.title, location: doc.location,
                         snippet: Self.excerpt(passage.text, terms: terms), terms: terms, score: score,
                         anchor: sourceAnchor(doc, passage: passage, terms: terms))
    }

}

@MainActor
final class NoteSearchModel: ObservableObject {
    @Published var query = ""
    @Published var results: [NoteSearchResult] = []
    @Published var selection = 0
    @Published var busy = false
    @Published var noteCount = 0
    @Published var skipped = 0
    private let queue = DispatchQueue(label: "Folio.note-search", qos: .userInitiated)
    private let index = NoteSearchIndex()
    private var pending: DispatchWorkItem?
    private var generation = UUID()
    func update(_ notebook: Notebook, immediate: Bool = false) {
        pending?.cancel()
        let generation = UUID(); self.generation = generation
        let query = query, roots = notebook.roots, archived = notebook.library.archived
        let draft = notebook.selected.map { ($0, notebook.text) }
        let recent = UserDefaults.standard.stringArray(forKey: "recentNotes") ?? []
        busy = true
        let previous = selection < results.count ? results[selection].id : nil
        let task = DispatchWorkItem { [weak self, index] in
            index.refresh(roots: roots, draft: draft, excluding: archived)
            let results = index.search(query, recent: recent)
            let count = index.documents.count, skipped = index.skipped
            DispatchQueue.main.async { [weak self] in
                guard let self, self.generation == generation else { return }
                self.results = results; self.noteCount = count; self.skipped = skipped; self.busy = false
                self.selection = immediate ? results.firstIndex(where: { $0.id == previous }) ?? 0 : 0
            }
        }
        pending = task
        queue.asyncAfter(deadline: .now() + (immediate ? 0 : 0.08), execute: task)
    }
    func cancel() { pending?.cancel(); generation = UUID(); busy = false }
    func move(_ direction: Int) { if !results.isEmpty { selection = (selection + direction + results.count) % results.count } }
}

struct PaletteSearchField: NSViewRepresentable {
    @Binding var text: String
    let scale: CGFloat
    let action: (String) -> Void
    final class Field: NSTextField {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            DispatchQueue.main.async { [weak self] in
                guard let self, let window = self.window else { return }
                window.makeFirstResponder(self)
            }
        }
    }
    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: PaletteSearchField
        init(_ parent: PaletteSearchField) { self.parent = parent }
        func controlTextDidChange(_ notification: Notification) {
            if let field = notification.object as? NSTextField { parent.text = field.stringValue }
        }
        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            let command = NSStringFromSelector(selector)
            if ["moveUp:", "moveDown:", "insertNewline:", "cancelOperation:"].contains(command) { parent.action(command); return true }
            return false
        }
    }
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> Field {
        let field = Field(string: text)
        field.isBordered = false; field.drawsBackground = false; field.focusRingType = .none
        field.placeholderString = "Search your notes…"; field.delegate = context.coordinator
        field.setAccessibilityLabel("Search all notes")
        field.cell?.usesSingleLineMode = true
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return field
    }
    func updateNSView(_ view: Field, context: Context) {
        context.coordinator.parent = self
        view.font = .systemFont(ofSize: 15 * scale); view.textColor = Ink.text
        if view.stringValue != text { view.stringValue = text }
    }
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: Field, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 100, height: proposal.height ?? 22 * scale)
    }
}

struct NoteSearchPalette: View {
    @ObservedObject var notebook: Notebook
    @ObservedObject var search: NoteSearchModel
    let dismiss: () -> Void
    var scale: CGFloat { CGFloat(notebook.zoom) }
    private var emptyQuery: Bool { search.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    private var selectedResult: NoteSearchResult? { search.selection < search.results.count ? search.results[search.selection] : nil }
    func open(_ result: NoteSearchResult) { notebook.selectSearchResult(result) }
    func command(_ command: String) {
        switch command {
        case "moveUp:": search.move(-1)
        case "moveDown:": search.move(1)
        case "insertNewline:": if !search.busy, let result = selectedResult { open(result) }
        case "cancelOperation:": dismiss()
        default: break
        }
    }
    func highlighted(_ text: String, terms: Set<String>, size: CGFloat = 12) -> Text {
        let ns = text as NSString
        let expression = try! NSRegularExpression(pattern: #"[\p{L}\p{M}\p{N}]+"#)
        var value = AttributedString(text)
        for match in expression.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            guard terms.contains(NoteSearchIndex.folded(ns.substring(with: match.range))),
                  let range = Range(match.range, in: text), let lower = AttributedString.Index(range.lowerBound, within: value), let upper = AttributedString.Index(range.upperBound, within: value) else { continue }
            value[lower..<upper].foregroundColor = Color(nsColor: Ink.color(0x1776C7, 0x84BFFF))
            value[lower..<upper].backgroundColor = Color(nsColor: Ink.accent).opacity(0.13)
            value[lower..<upper].font = .system(size: size * scale, weight: .medium)
        }
        return Text(value)
    }
    var header: some View {
        HStack(spacing: 10 * scale) {
            OpusIcon(glyph: "\u{f002}", size: 13 * scale).foregroundStyle(Color(nsColor: Ink.muted))
            PaletteSearchField(text: $search.query, scale: scale, action: command).frame(height: 22 * scale)
            Button("esc", action: dismiss).buttonStyle(.plain)
                .font(.system(size: 10 * scale, design: .monospaced)).foregroundStyle(Color(nsColor: Ink.muted))
                .padding(.horizontal, 5 * scale).padding(.vertical, 3 * scale)
                .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color(nsColor: Ink.separator), lineWidth: 1))
                .accessibilityLabel("Close search")
        }.padding(.horizontal, 17 * scale).frame(height: min(52 * scale, 78))
    }
    func resultRow(_ result: NoteSearchResult, at position: Int, width: CGFloat) -> some View {
        Button { open(result) } label: {
            HStack(spacing: 10 * scale) {
                OpusIcon(glyph: "\u{f15b}", size: 11 * scale, regular: true)
                    .foregroundStyle(Color(nsColor: notebook.tint(for: result.root).color))
                if emptyQuery {
                    Text(result.title).font(.system(size: 13 * scale, weight: .medium)).lineLimit(1)
                    Spacer(minLength: 15 * scale)
                    Text(result.location).font(.system(size: 11 * scale)).foregroundStyle(Color(nsColor: Ink.muted)).lineLimit(1).truncationMode(.middle)
                } else {
                    highlighted(result.title, terms: result.terms, size: 13)
                        .font(.system(size: 13 * scale, weight: .medium)).lineLimit(1)
                        .frame(width: min(132 * scale, width * 0.25), alignment: .leading)
                    highlighted(result.snippet.isEmpty ? "Empty note" : result.snippet, terms: result.terms)
                        .font(.system(size: 12 * scale)).foregroundStyle(Color(nsColor: Ink.muted))
                        .lineLimit(1).truncationMode(.tail).frame(maxWidth: .infinity, alignment: .leading)
                }
            }.padding(.horizontal, 11 * scale).frame(height: 39 * scale)
                .frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                .background(position == search.selection ? Color(nsColor: Ink.accent).opacity(0.10) : .clear, in: RoundedRectangle(cornerRadius: 5 * scale))
        }.buttonStyle(.plain).id(result.id).help(result.location + " / " + result.title)
            .onHover { inside in if inside { search.selection = position } }
            .accessibilityLabel(result.title + ", " + result.location + (emptyQuery ? "" : ". " + result.snippet))
    }
    func resultList(width: CGFloat) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 2 * scale) {
                    ForEach(Array(search.results.enumerated()), id: \.element.id) { position, result in
                        resultRow(result, at: position, width: width)
                    }
                }.padding(.horizontal, 7 * scale).padding(.bottom, 7 * scale)
            }.scrollIndicators(.never)
                .onChange(of: search.selection) { _, value in if value < search.results.count { proxy.scrollTo(search.results[value].id) } }
                .onChange(of: search.results.first?.id) { _, value in if let value { proxy.scrollTo(value, anchor: .top) } }
        }
    }
    func footer(width: CGFloat) -> some View {
        HStack(spacing: 12 * scale) {
            if let result = selectedResult {
                Circle().fill(Color(nsColor: notebook.tint(for: result.root).color)).frame(width: 5 * scale, height: 5 * scale)
                Text(result.location).lineLimit(1).truncationMode(.middle)
            } else { Text(search.skipped > 0 ? "\(search.skipped) files unavailable" : "Search all notebooks") }
            Spacer(minLength: 10 * scale)
            if width / scale >= 360 { Text("↑↓ select"); Text("↵ open") }
            else { Text("↵").fixedSize() }
        }.font(.system(size: 10 * scale)).foregroundStyle(Color(nsColor: Ink.muted))
            .padding(.horizontal, 17 * scale).frame(height: min(31 * scale, 46))
    }
    var body: some View {
        GeometryReader { geometry in
            let margin = min(32, max(12, geometry.size.width * 0.04))
            let width = max(0, min(580 * scale, geometry.size.width - margin * 2))
            let desiredHeight: CGFloat = search.results.isEmpty ? 190 : 117 + CGFloat(min(search.results.count, 7)) * 41
            let top = min(90 * scale, max(12, geometry.size.height * 0.1))
            let height = max(0, min(desiredHeight * scale, geometry.size.height - top - 16))
            ZStack(alignment: .top) {
                Color.black.opacity(0.16).contentShape(Rectangle()).onTapGesture { dismiss() }
                VStack(spacing: 0) {
                    header
                    Rectangle().fill(Color(nsColor: Ink.separator)).frame(height: 1)
                    HStack {
                        Text(emptyQuery ? "Recent" : "Matches")
                        Spacer()
                        Text(search.busy ? "Searching…" : search.skipped > 0 ? "\(search.skipped) files unavailable" : emptyQuery ? "All notebooks" : "\(search.results.count) \(search.results.count == 1 ? "note" : "notes")")
                    }.font(.system(size: 10 * scale)).foregroundStyle(Color(nsColor: Ink.muted)).lineLimit(1)
                        .padding(.horizontal, 18 * scale).frame(height: min(27 * scale, 40))
                    if search.results.isEmpty {
                        VStack(spacing: 7 * scale) {
                            Text(search.busy ? "Searching your notes…" : emptyQuery ? "Your notes will appear here" : "No matching notes")
                                .font(.system(size: 13 * scale, weight: .medium)).lineLimit(2)
                            if !search.busy && height / scale > 180 { Text(emptyQuery ? "Open a notebook to get started." : "Try a name or a few different words.")
                                .font(.system(size: 11 * scale)).foregroundStyle(Color(nsColor: Ink.muted)) }
                        }.padding(.horizontal, 16).frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else { resultList(width: width) }
                    Rectangle().fill(Color(nsColor: Ink.separator)).frame(height: 1)
                    footer(width: width)
                }.foregroundStyle(Color(nsColor: Ink.text)).frame(width: width, height: height)
                    .background(Color(nsColor: Ink.paper), in: RoundedRectangle(cornerRadius: 10 * scale))
                    .overlay(RoundedRectangle(cornerRadius: 10 * scale).stroke(Color(nsColor: Ink.separator), lineWidth: 1))
                    .shadow(color: .black.opacity(0.24), radius: 28, y: 12)
                    .padding(.top, top)
            }
        }
        .onAppear { search.update(notebook, immediate: true) }
        .onChange(of: search.query) { _, _ in search.update(notebook) }
        .onReceive(Timer.publish(every: 2, on: .main, in: .common).autoconnect()) { _ in
            if !search.busy { search.update(notebook, immediate: true) }
        }
        .onDisappear { search.cancel() }
    }
}
