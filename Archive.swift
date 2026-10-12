import SwiftUI

struct ArchiveBrowser: View {
    @ObservedObject var notebook: Notebook
    let dismiss: () -> Void
    private var scale: CGFloat { min(CGFloat(notebook.zoom), 1.3) }
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8 * scale) {
                Text("Archive").font(.system(size: 13 * scale, weight: .semibold))
                Text("\(notebook.archivedEntries.count)").foregroundStyle(Color(nsColor: Ink.muted))
                Spacer()
            }.padding(14 * scale)
            Divider().opacity(0.5)
            if notebook.archivedEntries.isEmpty {
                VStack(spacing: 10 * scale) {
                    OpusIcon(glyph: "\u{f187}", size: 22 * scale).foregroundStyle(Color(nsColor: Ink.muted).opacity(0.65))
                    Text("No archived items").fontWeight(.medium)
                    Text("Right-click a note or folder and choose Archive. You can restore it here anytime.")
                        .font(.system(size: 11 * scale)).foregroundStyle(Color(nsColor: Ink.muted))
                        .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
                }.padding(26 * scale).frame(maxWidth: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 4 * scale) {
                        ForEach(notebook.archivedEntries) { entry in
                            ArchiveItem(entry: entry, notebook: notebook, scale: scale, dismiss: dismiss)
                        }
                    }.padding(8 * scale)
                }.frame(maxHeight: 340 * scale)
                Divider().opacity(0.5)
                Text("Files stay safely in their original folders.")
                    .font(.system(size: 10 * scale)).foregroundStyle(Color(nsColor: Ink.muted))
                    .padding(.horizontal, 14 * scale).padding(.vertical, 10 * scale)
            }
        }
        .font(.system(size: 12 * scale)).foregroundStyle(Color(nsColor: Ink.text))
        .frame(width: 290 * scale).background(Color(nsColor: Ink.paper))
    }
}

private struct ArchiveItem: View {
    let entry: NoteEntry
    @ObservedObject var notebook: Notebook
    let scale: CGFloat
    let dismiss: () -> Void
    var nested = false
    @State private var expanded = false
    var body: some View {
        VStack(alignment: .leading, spacing: 3 * scale) {
            HStack(spacing: 4 * scale) {
                Button {
                    if entry.isFolder { expanded.toggle() }
                    else { notebook.select(entry.url); dismiss() }
                } label: {
                    HStack(spacing: 8 * scale) {
                        OpusIcon(glyph: entry.isFolder ? (expanded ? "\u{f07c}" : "\u{f07b}") : entry.isTaskPage ? "\u{f0ae}" : "\u{f15b}", size: 11 * scale, regular: !entry.isFolder && !entry.isTaskPage)
                            .foregroundStyle(Color(nsColor: Ink.muted))
                        VStack(alignment: .leading, spacing: 3 * scale) {
                            Text(entry.name).lineLimit(1)
                            if !nested {
                                Text(entry.url.deletingLastPathComponent().lastPathComponent)
                                    .font(.system(size: 10 * scale)).foregroundStyle(Color(nsColor: Ink.muted)).lineLimit(1)
                            }
                        }
                        Spacer(minLength: 0)
                    }.padding(7 * scale).contentShape(Rectangle())
                }.buttonStyle(.plain).accessibilityLabel((entry.isFolder ? "Expand " : "Open ") + entry.name)
                if !nested {
                    Button { notebook.toggleArchive(entry.url) } label: {
                        OpusIcon(glyph: "\u{f0e2}", size: 11 * scale).frame(width: 28 * scale, height: 30 * scale).contentShape(Rectangle())
                    }.buttonStyle(.plain).foregroundStyle(Color(nsColor: Ink.muted))
                        .help("Restore \(entry.name)").accessibilityLabel("Restore \(entry.name) from Archive")
                }
            }
            if expanded {
                if entry.children.isEmpty {
                    Text("Empty folder").font(.system(size: 11 * scale)).foregroundStyle(Color(nsColor: Ink.muted)).padding(.leading, 24 * scale).padding(.vertical, 6 * scale)
                }
                ForEach(entry.children) { child in
                    ArchiveItem(entry: child, notebook: notebook, scale: scale, dismiss: dismiss, nested: true).padding(.leading, 12 * scale)
                }
            }
        }
    }
}
