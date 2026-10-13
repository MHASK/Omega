import SwiftUI
import AppKit
import CoreText
import UniformTypeIdentifiers

// These are the exact Font Awesome 5.1.0 glyphs used by Opus.
enum OpusIcons {
    static func register() {
        for name in ["fa-solid-900", "fa-regular-400"] {
            if let url = Bundle.main.url(forResource: name, withExtension: "ttf") {
                CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
            }
        }
    }
}

struct OpusIcon: View {
    let glyph: String
    var size: CGFloat = 12
    var regular = false
    var body: some View {
        Text(glyph)
            .font(.custom(regular ? "FontAwesome5FreeRegular" : "FontAwesome5FreeSolid", size: size))
            .frame(width: size * 1.25, height: size * 1.4)
            .accessibilityHidden(true)
    }
}

struct WindowDragRegion: NSViewRepresentable {
    final class DragView: NSView {
        override var mouseDownCanMoveWindow: Bool { true }
        override func mouseDown(with event: NSEvent) {
            if event.clickCount == 2 { window?.performZoom(nil) }
            else { window?.performDrag(with: event) }
        }
    }
    func makeNSView(context: Context) -> NSView { DragView() }
    func updateNSView(_ nsView: NSView, context: Context) {}
}

struct FolderFrames: PreferenceKey {
    static var defaultValue: [URL: CGRect] = [:]
    static func reduce(value: inout [URL: CGRect], nextValue: () -> [URL: CGRect]) { value.merge(nextValue(), uniquingKeysWith: { _, new in new }) }
}

struct SidebarDivider: NSViewRepresentable {
    let width: CGFloat
    let scale: CGFloat
    let onResize: (Double) -> Void
    final class DividerView: NSView {
        var width: CGFloat = 215
        var scale: CGFloat = 1
        var onResize: ((Double) -> Void)?
        private var cursorTracking: NSTrackingArea?
        override func resetCursorRects() {
            super.resetCursorRects()
            addCursorRect(visibleRect, cursor: .resizeLeftRight)
        }
        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            if let cursorTracking { removeTrackingArea(cursorTracking) }
            let tracking = NSTrackingArea(rect: .zero, options: [.inVisibleRect, .activeAlways, .cursorUpdate, .mouseEnteredAndExited, .mouseMoved], owner: self)
            addTrackingArea(tracking); cursorTracking = tracking
        }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            window?.invalidateCursorRects(for: self)
        }
        override func setFrameSize(_ newSize: NSSize) {
            super.setFrameSize(newSize)
            window?.invalidateCursorRects(for: self)
        }
        override func cursorUpdate(with event: NSEvent) { NSCursor.resizeLeftRight.set() }
        override func mouseEntered(with event: NSEvent) { NSCursor.resizeLeftRight.set() }
        override func mouseMoved(with event: NSEvent) { NSCursor.resizeLeftRight.set() }
        override func mouseExited(with event: NSEvent) { NSCursor.arrow.set() }
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
        override func isAccessibilityElement() -> Bool { true }
        override func accessibilityRole() -> NSAccessibility.Role? { .splitter }
        override func accessibilityLabel() -> String? { "Sidebar width" }
        override func accessibilityValue() -> Any? { Int(width / scale) }
        override func accessibilityOrientation() -> NSAccessibilityOrientation { .vertical }
        override func accessibilityPerformIncrement() -> Bool { onResize?(Double(width / scale + 20)); return true }
        override func accessibilityPerformDecrement() -> Bool { onResize?(Double(width / scale - 20)); return true }
        override func mouseDown(with event: NSEvent) {
            guard let window else { return }
            NSCursor.resizeLeftRight.set()
            defer {
                if visibleRect.contains(convert(window.mouseLocationOutsideOfEventStream, from: nil)) { NSCursor.resizeLeftRight.set() }
                else { NSCursor.arrow.set() }
            }
            if event.clickCount == 2 { onResize?(215); return }
            let origin = event.locationInWindow.x, initial = width
            while let next = window.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) {
                if next.type == .leftMouseUp { break }
                NSCursor.resizeLeftRight.set()
                onResize?(Double((initial + next.locationInWindow.x - origin) / scale))
            }
        }
    }
    func makeNSView(context: Context) -> DividerView { DividerView() }
    func updateNSView(_ view: DividerView, context: Context) { view.width = width; view.scale = scale; view.onResize = onResize }
}

// Content recedes into its own surface; the footer controls have no bar behind them.
struct ScrollEdgeFade: View {
    let surface: NSColor
    let height: CGFloat
    var body: some View {
        LinearGradient(colors: [Color(nsColor: surface).opacity(0), Color(nsColor: surface)], startPoint: .top, endPoint: .bottom)
            .frame(height: height)
            .allowsHitTesting(false).accessibilityHidden(true)
    }
}

struct FolioView: View {
    @ObservedObject var notebook: Notebook
    @ObservedObject private var updater = GitHubUpdater.shared
    @ObservedObject private var gitSync = GitNotebooks.shared
    @StateObject private var noteSearch = NoteSearchModel()
    @State private var sidebarToggleHovered = false
    @State private var showingArchive = false
    var scale: CGFloat { CGFloat(notebook.zoom) }
    var toolbarScale: CGFloat { min(scale, 1.5) }
    var headerHeight: CGFloat { min(40 * scale, 56) }
    var footerHeight: CGFloat { min(36 * scale, 52) }

    var body: some View {
        ZStack {
            workspace.opacity(notebook.showingSettings || gitSync.reviewing != nil ? 0 : 1)
                .allowsHitTesting(!notebook.showingSettings && gitSync.reviewing == nil).accessibilityHidden(notebook.showingSettings || gitSync.reviewing != nil)
            if notebook.showingSettings {
                FolioSettingsView(notebook: notebook)
                    .opacity(gitSync.reviewing == nil ? 1 : 0)
                    .allowsHitTesting(gitSync.reviewing == nil).accessibilityHidden(gitSync.reviewing != nil)
            }
            if let path = gitSync.reviewing, let entry = gitSync.notebooks.first(where: { $0.path == path }) { GitConflictView(notebook: notebook, entry: entry) }
        }
        .preferredColorScheme(notebook.appearance == "system" ? nil : notebook.appearance == "dark" ? .dark : .light)
    }
    var workspace: some View {
        GeometryReader { geometry in
            let minimumSidebar = 160 * scale
            let minimumDocument = max(320, 360 * scale)
            let compact = geometry.size.width < minimumSidebar + minimumDocument
            let docked = notebook.sidebar && !compact
            // Task controls occupy the document's top edge when the window controls are in the sidebar.
            let edgeTaskHeader = docked && notebook.selected != nil && notebook.text.hasPrefix(TaskDocument.marker)
            let width = compact
                ? min(max(220, CGFloat(notebook.sidebarWidth) * scale), max(180, geometry.size.width - 32))
                : min(CGFloat(notebook.sidebarWidth) * scale, max(minimumSidebar, geometry.size.width - minimumDocument))
            let documentWidth = max(0, geometry.size.width - (docked ? width : 0))
            HStack(spacing: 0) {
                if docked {
                    sidebar.frame(width: width)
                }
                VStack(spacing: 0) {
                    if notebook.selected != nil {
                        RichEditor(notebook: notebook)
                            .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
                            .overlay(alignment: .bottom) { ScrollEdgeFade(surface: Ink.paper, height: 24 * scale) }
                    } else {
                        VStack(alignment: .leading, spacing: 18 * scale) {
                            Text(notebook.loading ? "Opening folder…" : "No note selected")
                                .font(.system(size: 20 * scale, weight: .semibold))
                            if !notebook.loading {
                                Button("New note  ⌘N") { notebook.newNote() }.disabled(notebook.root == nil)
                                Button("Open folder…") { notebook.chooseFolder() }
                            }
                            Spacer()
                        }.font(.system(size: 13 * scale)).buttonStyle(.plain)
                            .padding(.top, 6 * scale).padding(.horizontal, min(50 * scale, documentWidth * 0.08))
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    }
                    footer(width: documentWidth)
                }.frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
                    .padding(.top, edgeTaskHeader ? 0 : headerHeight).background(Color(nsColor: Ink.paper))
            }
            .frame(width: geometry.size.width, height: geometry.size.height, alignment: .topLeading)
            .overlay(alignment: .leading) {
                if docked {
                    // Straddle the seam so the resize target works from either side.
                    SidebarDivider(width: width, scale: scale) { notebook.resizeSidebar($0) }
                        .frame(width: 12, height: geometry.size.height)
                        .offset(x: width - 6)
                        .help("Drag to resize · Double-click to reset")
                        .accessibilityLabel("Resize sidebar")
                }
            }
            .overlay(alignment: .leading) {
                if compact && notebook.sidebarOverlay {
                    ZStack(alignment: .leading) {
                        Color.black.opacity(0.12).contentShape(Rectangle()).onTapGesture { notebook.sidebarOverlay = false }
                            .accessibilityLabel("Close sidebar").accessibilityAddTraits(.isButton)
                        sidebar.frame(width: width)
                    }
                }
            }
            .overlay(alignment: .top) {
                HStack(spacing: 0) {
                    sidebarToolbar.frame(width: docked || (compact && notebook.sidebarOverlay) ? width : min(240 * toolbarScale, max(150, geometry.size.width - 142 * toolbarScale)))
                    WindowDragRegion().frame(maxWidth: .infinity).allowsHitTesting(!edgeTaskHeader)
                    if !edgeTaskHeader && notebook.selected != nil && !(compact && notebook.sidebarOverlay) {
                        DocumentToolbar(notebook: notebook)
                            .padding(.trailing, 12 * toolbarScale)
                            .padding(.top, max(0, 19 - 12 * toolbarScale))
                    }
                }.frame(height: headerHeight, alignment: .top)
            }
            .clipped()
            .onAppear { notebook.visibleSidebarWidth = width; notebook.adaptSidebar(compact: compact) }
            .onChange(of: width) { _, value in notebook.visibleSidebarWidth = value }
            .onChange(of: compact) { _, value in notebook.adaptSidebar(compact: value) }
        }
        .foregroundStyle(Color(nsColor: Ink.text))
        .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
        .ignoresSafeArea()
        .overlay {
            if notebook.searching {
                NoteSearchPalette(notebook: notebook, search: noteSearch) { notebook.searching = false }
            }
        }
        .onChange(of: notebook.searching) { _, visible in
            if !visible { DispatchQueue.main.async { if notebook.searchReveal == nil { notebook.richEditor?.focus() } } }
        }
        .preferredColorScheme(notebook.appearance == "system" ? nil : notebook.appearance == "dark" ? .dark : .light)
        .onReceive(NotificationCenter.default.publisher(for: .init("FolioSearch"))) { _ in
            guard !notebook.showingSettings else { return }
            if notebook.searching { notebook.searching = false }
            else {
                notebook.afterSync {
                    noteSearch.query = ""; noteSearch.results = []; noteSearch.selection = 0
                    notebook.searching = true
                }
            }
        }
    }

    func openSearch() {
        if !notebook.searching { NotificationCenter.default.post(name: .init("FolioSearch"), object: nil) }
    }
    var sidebarToolbar: some View {
        HStack(spacing: 8 * toolbarScale) {
            Button { notebook.toggleSidebar() } label: {
                Image(systemName: notebook.sidebarIsVisible ? "rectangle.lefthalf.inset.filled.arrow.left" : "sidebar.left")
                    .font(.system(size: 13 * toolbarScale, weight: .regular))
                    .frame(width: 24 * toolbarScale, height: 24 * toolbarScale)
                    .contentShape(Rectangle())
                    .background(Color(nsColor: Ink.muted).opacity(sidebarToggleHovered ? 0.12 : 0), in: RoundedRectangle(cornerRadius: 4 * scale))
            }.buttonStyle(.plain)
                .onHover { sidebarToggleHovered = $0 }
                .accessibilityLabel(notebook.sidebarIsVisible ? "Hide sidebar" : "Show sidebar")
                .help((notebook.sidebarIsVisible ? "Hide sidebar" : "Show sidebar") + " · ⌘\\")
            ViewThatFits(in: .horizontal) {
                noteCountLabel(compact: false)
                noteCountLabel(compact: true)
                Color.clear.frame(width: 0, height: 24 * toolbarScale)
            }
            Spacer(minLength: 0)
            Button { NSApp.sendAction(#selector(AppDelegate.showSettings), to: NSApp.delegate, from: nil) } label: {
                OpusIcon(glyph: "\u{f013}", size: 11 * toolbarScale)
                    .frame(width: 24 * toolbarScale, height: 24 * toolbarScale).contentShape(Rectangle())
            }.buttonStyle(.plain).help(updater.readyVersion == nil ? "Settings · ⌘," : "Settings · Update ready").accessibilityLabel("Settings")
                .overlay(alignment: .topTrailing) { if updater.readyVersion != nil { Circle().fill(Color(nsColor: NotebookTint.lavender.color)).frame(width: 5, height: 5).allowsHitTesting(false) } }

        }.foregroundStyle(Color(nsColor: Ink.muted))
            .padding(.leading, notebook.fullscreen ? 12 * toolbarScale : 80).padding(.trailing, 12 * toolbarScale)
            .padding(.top, max(0, 19 - 12 * toolbarScale))
            .frame(height: headerHeight, alignment: .top)
            .background(WindowDragRegion())
    }
    func noteCountLabel(compact: Bool) -> some View {
        HStack(spacing: 6 * toolbarScale) {
            OpusIcon(glyph: "\u{f15b}", size: 10 * toolbarScale, regular: true)
            Text(compact ? "\(notebook.totalNoteCount)" : "\(notebook.totalNoteCount) \(notebook.totalNoteCount == 1 ? "note" : "notes")")
                .font(.system(size: 11 * toolbarScale)).monospacedDigit()
        }.frame(height: 24 * toolbarScale).fixedSize()
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(notebook.totalNoteCount) notes across all notebooks")
            .help("Total notes across all open notebooks")
            .allowsHitTesting(false)
    }
    var sidebarSearchBar: some View {
        HStack(spacing: 0) {
            Button(action: openSearch) {
                HStack(spacing: 8 * scale) {
                    OpusIcon(glyph: "\u{f002}", size: 10 * scale)
                    Text("Search notes").font(.system(size: 12 * scale)).lineLimit(1)
                    Spacer(minLength: 0)
                    Text("⌘K").font(.system(size: 10 * scale, design: .monospaced))
                }
                .padding(.leading, 12 * scale).padding(.trailing, 5 * scale)
                .frame(maxWidth: .infinity).frame(height: footerHeight)
                .contentShape(Rectangle())
            }.buttonStyle(.plain).accessibilityLabel("Search all notes, Command K")
            Button { showingArchive.toggle() } label: {
                OpusIcon(glyph: "\u{f187}", size: 11 * scale)
                    .frame(width: 30 * scale, height: footerHeight).contentShape(Rectangle())
            }.buttonStyle(.plain).padding(.trailing, 5 * scale)
                .help("Archived notes and folders").accessibilityLabel("Show archived items")
                .popover(isPresented: $showingArchive, arrowEdge: .top) {
                    ArchiveBrowser(notebook: notebook) { showingArchive = false }
                }
        }.foregroundStyle(Color(nsColor: Ink.muted))
            .overlay(alignment: .top) {
                Rectangle().fill(Color(nsColor: Ink.separator)).frame(height: 1)
                    .allowsHitTesting(false).accessibilityHidden(true)
            }
    }

    var sidebar: some View {
        VStack(spacing: 0) {
            Color.clear.frame(height: headerHeight)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8 * scale) {
                    if !notebook.favoriteEntries.isEmpty {
                        Text("Favorites").font(.system(size: 10 * scale, weight: .medium)).foregroundStyle(Color(nsColor: Ink.muted)).padding(.leading, 12 * scale)
                        ForEach(notebook.favoriteEntries) { entry in NoteRow(entry: entry, level: -1, rootFolder: notebook.owner(of: entry.url) ?? entry.url.deletingLastPathComponent(), notebook: notebook) }
                    }
                    ForEach(notebook.roots, id: \.path) { folder in
                        NotebookSection(folder: folder, notebook: notebook)
                    }
                    if !notebook.archivedEntries.isEmpty {
                        Button { notebook.archiveExpanded.toggle() } label: {
                            HStack(spacing: 7 * scale) {
                                OpusIcon(glyph: "\u{f187}", size: 10 * scale)
                                Text("Archive").font(.system(size: 11 * scale))
                                Text("\(notebook.archivedEntries.count)").font(.system(size: 10 * scale)).opacity(0.7)
                                Spacer()
                                OpusIcon(glyph: notebook.archiveExpanded ? "\u{f107}" : "\u{f105}", size: 10 * scale)
                            }.foregroundStyle(Color(nsColor: Ink.muted)).padding(10 * scale).contentShape(Rectangle())
                        }.buttonStyle(.plain).help("Archived notes stay safely on your Mac")
                        if notebook.archiveExpanded {
                            ForEach(notebook.archivedEntries) { entry in NoteRow(entry: entry, level: -1, rootFolder: notebook.owner(of: entry.url) ?? entry.url.deletingLastPathComponent(), notebook: notebook) }
                        }
                    }
                }
                .padding(.horizontal, 8 * scale).padding(.bottom, 20 * scale)
            }.scrollIndicators(.never)
                .overlay(alignment: .bottom) { ScrollEdgeFade(surface: Ink.sidebar, height: 20 * scale) }
            sidebarSearchBar
        }
        .foregroundStyle(Color(nsColor: Ink.sidebarText))
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Color(nsColor: Ink.sidebar))
        .overlay(alignment: .trailing) { Rectangle().fill(Color(nsColor: Ink.separator)).frame(width: 1) }
        .contextMenu {
            Button("New note") { notebook.newNote() }
            Button("New task page") { notebook.newTaskPage() }
            Button("New folder…") { notebook.newFolder() }
            Divider()
            Button("New notebook…") { notebook.newNotebook() }
            Button("Open folder…") { notebook.chooseFolder() }
        }
        .coordinateSpace(name: "notebookTree")
        .background(GeometryReader { proxy in Color.clear.onAppear { notebook.sidebarHeight = proxy.size.height }.onChange(of: proxy.size.height) { _, value in notebook.sidebarHeight = value } })
        .onPreferenceChange(FolderFrames.self) { notebook.dropFrames = $0 }
        .overlay(alignment: .topLeading) {
            if let dragged = notebook.draggedURL {
                Text(dragged.deletingPathExtension().lastPathComponent)
                    .font(.system(size: 12 * scale)).foregroundStyle(Color(nsColor: Ink.sidebarText))
                    .padding(.horizontal, 10 * scale).padding(.vertical, 6 * scale)
                    .background(Color(nsColor: Ink.paper), in: RoundedRectangle(cornerRadius: 5 * scale))
                    .overlay(RoundedRectangle(cornerRadius: 5 * scale).stroke(Color(nsColor: Ink.separator), lineWidth: 1))
                    .shadow(color: .black.opacity(0.08), radius: 6, y: 2)
                    .fixedSize().offset(x: notebook.dragPoint.x + 10 * scale, y: notebook.dragPoint.y - 12 * scale)
                    .allowsHitTesting(false)
            }
        }
        .overlay(alignment: .bottom) {
            if notebook.dragPromotesNotebook {
                HStack(spacing: 7 * scale) {
                    OpusIcon(glyph: "\u{f02d}", size: 11 * scale)
                    Text("Move to top level").font(.system(size: 11 * scale))
                }.foregroundStyle(Color(nsColor: Ink.accent))
                    .frame(maxWidth: .infinity).padding(.vertical, 12 * scale)
                    .background(Color(nsColor: Ink.accent).opacity(0.08), in: RoundedRectangle(cornerRadius: 5 * scale))
                    .overlay(RoundedRectangle(cornerRadius: 5 * scale).stroke(Color(nsColor: Ink.accent).opacity(0.3), style: StrokeStyle(lineWidth: 1, dash: [3, 3])))
                    .padding(12 * scale).padding(.bottom, 36 * scale).allowsHitTesting(false)
            }
        }
        .onDrop(of: [.fileURL], isTargeted: nil) { notebook.receiveRootDrop($0) }
    }

    func footer(width: CGFloat) -> some View {
        let compact = width / scale < 520
        let narrow = width / scale < 300
        return Group {
                HStack(spacing: 10 * scale) {
                    GitSyncIndicator(notebook: notebook)
                    LiveStatusView(notebook: notebook)
                    if !compact { Text("\(notebook.cursorLine):\(notebook.cursorColumn)").frame(maxWidth: .infinity, alignment: .leading) }
                    Text(narrow ? "\(NoteFiles.wordCount(notebook.text))W" : "\(notebook.lineCount)L \(NoteFiles.wordCount(notebook.text))W")
                        .fixedSize(horizontal: true, vertical: false)
                        .frame(maxWidth: compact ? nil : .infinity, alignment: .leading)
                    if let selected = notebook.selected {
                        Button { notebook.rename(selected) } label: {
                            Text(selected.deletingPathExtension().lastPathComponent).underline(notebook.dirty).truncationMode(.middle)
                        }.buttonStyle(.plain).frame(minWidth: 0, maxWidth: .infinity, alignment: .trailing).help(notebook.status + " · Click to rename")
                    }
                    if !compact { TimelineView(.periodic(from: .now, by: 60)) { context in
                        Text(context.date, format: .dateTime.hour().minute())
                    }.frame(maxWidth: .infinity, alignment: .trailing) }
                }.lineLimit(1)
        }
        .font(.system(size: 12 * scale, design: .monospaced))
        .foregroundStyle(Color(nsColor: Ink.muted))
        .padding(.horizontal, min(35 * scale, max(12, width * 0.045))).frame(height: footerHeight)
        .overlay(alignment: .top) {
            Rectangle().fill(Color(nsColor: Ink.separator)).frame(height: 1)
                .allowsHitTesting(false).accessibilityHidden(true)
        }
    }
}

struct NotebookSection: View {
    let folder: URL
    @ObservedObject var notebook: Notebook
    @State private var hovered = false
    @State private var dropTarget = false
    var scale: CGFloat { CGFloat(notebook.zoom) }
    var isExpanded: Bool { !notebook.collapsedNotebooks.contains(folder.path) }
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                Button {
                    notebook.creationFolder = folder
                    if isExpanded { notebook.collapsedNotebooks.insert(folder.path) }
                    else { notebook.collapsedNotebooks.remove(folder.path) }
                } label: {
                    HStack(spacing: 6 * scale) {
                        OpusIcon(glyph: isExpanded ? "\u{f107}" : "\u{f105}", size: 14 * scale).frame(width: 12 * scale)
                        OpusIcon(glyph: "\u{f02d}", size: 16 * scale).frame(width: 18 * scale)
                            .foregroundStyle(Color(nsColor: notebook.tint(for: folder).color))
                        Text(folder.lastPathComponent).font(.system(size: 16 * scale, weight: .bold))
                            .lineLimit(1)
                        Spacer(minLength: 0)
                    }.contentShape(Rectangle())
                }.buttonStyle(.plain).accessibilityLabel(folder.lastPathComponent + " notebook")
                Menu {
                    Button("New note") { notebook.newNote(in: folder) }
                    Button("New task page") { notebook.newTaskPage(in: folder) }
                    Button("New folder…") { notebook.newFolder(in: folder) }
                    Divider()
                    Button("New notebook…") { notebook.newNotebook(beside: folder) }
                    Button("Open folder…") { notebook.chooseFolder() }
                } label: {
                    OpusIcon(glyph: "\u{f067}", size: 10 * scale)
                        .foregroundStyle(Color(nsColor: Ink.sidebarText).opacity(hovered ? 0.85 : 0.35))
                        .frame(width: 24 * scale, height: 26 * scale).contentShape(Rectangle())
                }.menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                    .onHover { hovered = $0 }.help("Add note, folder, or notebook")
                    .accessibilityLabel("Add to " + folder.lastPathComponent)
            }.padding(.horizontal, 4 * scale).frame(height: 34 * scale)
                .background(dropTarget || notebook.dragDestination == folder ? Color(nsColor: Ink.accent).opacity(0.1) : .clear, in: RoundedRectangle(cornerRadius: 5 * scale))
                .background(GeometryReader { proxy in Color.clear.preference(key: FolderFrames.self, value: [folder: proxy.frame(in: .named("notebookTree"))]) })
                .onDrop(of: [.fileURL], isTargeted: $dropTarget) { notebook.receiveDrop($0, into: folder) }
                .contextMenu { ItemContextMenu(url: folder, isFolder: true, isNotebook: true, notebook: notebook) }
            if isExpanded {
                VStack(spacing: 0) {
                    ForEach(notebook.filteredEntries(in: folder)) { entry in NoteRow(entry: entry, level: 0, rootFolder: folder, notebook: notebook) }
                    if notebook.filteredEntries(in: folder).isEmpty && !notebook.query.isEmpty {
                        Text("No matching notes").font(.system(size: 12 * scale)).foregroundStyle(Color(nsColor: Ink.muted)).padding(15 * scale)
                    }
                }
            }
        }
    }
}

struct NoteRow: View {
    let entry: NoteEntry
    let level: Int
    let rootFolder: URL
    @ObservedObject var notebook: Notebook
    @State private var hovered = false
    @State private var dropTarget = false
    var scale: CGFloat { CGFloat(notebook.zoom) }
    var rootTint: Color { Color(nsColor: notebook.tint(for: rootFolder).color) }
    var selected: Bool { notebook.selected == entry.url }
    var targeted: Bool { entry.isFolder && (dropTarget || notebook.dragDestination == entry.url) }
    func activate() {
        if entry.isFolder {
            notebook.creationFolder = entry.url
            if notebook.expanded.contains(entry.id) { notebook.expanded.remove(entry.id) }
            else { notebook.expanded.insert(entry.id) }
        } else { notebook.select(entry.url) }
    }
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                HStack(spacing: 6 * scale) {
                    if entry.isFolder {
                        OpusIcon(glyph: notebook.expanded.contains(entry.id) ? "\u{f107}" : "\u{f105}", size: 12 * scale).frame(width: 12 * scale)
                    } else { Color.clear.frame(width: 12 * scale, height: 1).accessibilityHidden(true) }
                    OpusIcon(glyph: entry.isFolder ? "\u{f07b}" : entry.isTaskPage ? "\u{f0ae}" : "\u{f15b}", size: 12 * scale, regular: !entry.isFolder && !entry.isTaskPage).frame(width: 18 * scale)
                        .foregroundStyle(selected ? rootTint : Color(nsColor: Ink.sidebarText))
                    Text(entry.name).font(.system(size: 12 * scale)).lineLimit(1)
                    Spacer(minLength: 0)
                    if !entry.isFolder { FilePresenceView(url: entry.url, scale: scale) }
                }.frame(height: 30 * scale).contentShape(Rectangle())
                    .onTapGesture { activate() }
                    .highPriorityGesture(DragGesture(minimumDistance: 6 * scale, coordinateSpace: .named("notebookTree"))
                        .onChanged { notebook.updateDrag(entry.url, at: $0.location) }
                        .onEnded { _ in notebook.finishDrag() })
                    .accessibilityElement(children: .ignore).accessibilityLabel(entry.name)
                    .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton).accessibilityAction { activate() }
                if entry.isFolder {
                    Menu {
                        Button("New note") { notebook.newNote(in: entry.url) }
                        Button("New task page") { notebook.newTaskPage(in: entry.url) }
                        Button("New folder…") { notebook.newFolder(in: entry.url) }
                    } label: {
                        OpusIcon(glyph: "\u{f067}", size: 10 * scale).frame(width: 24 * scale, height: 26 * scale)
                    }.menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                        .opacity(hovered ? 0.6 : 0.001)
                        .help("Add inside \(entry.name)").accessibilityLabel("Add inside \(entry.name)")
                }
            }
            .foregroundStyle(Color(nsColor: Ink.sidebarText))
            .padding(.leading, min((4 + CGFloat(level + 1) * 12) * scale, max(16 * scale, notebook.visibleSidebarWidth * 0.3)))
            .padding(.trailing, 4 * scale).frame(height: 30 * scale)
            .background(selected ? rootTint.opacity(0.14) : targeted ? Color(nsColor: Ink.accent).opacity(0.12) : .clear, in: RoundedRectangle(cornerRadius: 5 * scale))
            .overlay { if targeted { RoundedRectangle(cornerRadius: 5 * scale).stroke(Color(nsColor: Ink.accent).opacity(0.5), lineWidth: 1) } }
            .overlay(alignment: notebook.dragOrderAfter ? .bottom : .top) {
                if notebook.dragOrderTarget == entry.url {
                    Capsule().fill(rootTint.opacity(0.8)).frame(height: 2).padding(.leading, 14 * scale).padding(.trailing, 4 * scale).allowsHitTesting(false)
                }
            }
            .contentShape(Rectangle())
            .background(GeometryReader { proxy in
                Color.clear.preference(key: FolderFrames.self, value: [entry.url: proxy.frame(in: .named("notebookTree"))])
            })
            .onContinuousHover { phase in
                switch phase { case .active: hovered = true; case .ended: hovered = false }
            }
            .onDrop(of: [.fileURL], isTargeted: $dropTarget) { providers in
                guard entry.isFolder else { return false }
                return notebook.receiveDrop(providers, into: entry.url)
            }
            .contextMenu { ItemContextMenu(url: entry.url, isFolder: entry.isFolder, isNotebook: notebook.roots.contains(entry.url), notebook: notebook) }
            if entry.isFolder && notebook.expanded.contains(entry.id) {
                ForEach(entry.children) { child in
                    NoteRow(entry: child, level: level + 1, rootFolder: rootFolder, notebook: notebook)
                }
            }
        }
    }
}


struct ItemContextMenu: View {
    let url: URL
    let isFolder: Bool
    let isNotebook: Bool
    @ObservedObject var notebook: Notebook
    var body: some View {
        if isFolder {
            Button("New note") { notebook.newNote(in: url) }
            Button("New task page") { notebook.newTaskPage(in: url) }
            Button("New folder…") { notebook.newFolder(in: url) }
            if isNotebook { Button("New notebook…") { notebook.newNotebook(beside: url) } }
            Divider()
        }
        if !isFolder {
            Button(notebook.library.favorites.contains(url.path) ? "Remove from Favorites" : "Add to Favorites") { notebook.toggleFavorite(url) }
        }
        if !isNotebook {
            Button(notebook.isArchived(url) ? "Restore from Archive" : "Archive") { notebook.toggleArchive(url) }
            Divider()
        }
        Button("Rename…") { notebook.rename(url) }
        if isNotebook {
            Menu("Color") {
                ForEach(NotebookTint.allCases, id: \.rawValue) { tint in
                    Toggle(tint.title, isOn: Binding(get: { notebook.tint(for: url) == tint }, set: { if $0 { notebook.setTint(tint, for: url) } }))
                }
                Divider()
                Button("Choose automatically") { notebook.setTint(nil, for: url) }
            }
        }
        if !isNotebook {
            Button("Duplicate") { notebook.duplicate(url) }
            Menu("Reorder") {
                Button("Move up") { notebook.shiftItem(url, down: false) }
                Button("Move down") { notebook.shiftItem(url, down: true) }
            }
            Menu("Move to") {
                ForEach(notebook.roots, id: \.path) { root in
                    FolderDestinationMenu(folder: NoteEntry(url: root, isFolder: true, children: notebook.trees[root] ?? []), source: url, notebook: notebook)
                }
                if isFolder {
                    Divider()
                    Button("Top level (new notebook)") { notebook.promoteNotebook(url) }
                }
            }
        }
        Divider()
        Button("Show in Finder") { notebook.reveal(url) }
        Button("Copy path") { notebook.copyPath(url) }
        Divider()
        if isNotebook {
            Button("Close notebook") { notebook.closeNotebook(url) }.help("Remove from the sidebar. Files stay on your Mac.")
        } else {
            Button("Move to Trash", role: .destructive) { notebook.trash(url) }
        }
    }
}

struct FolderDestinationMenu: View {
    let folder: NoteEntry
    let source: URL
    @ObservedObject var notebook: Notebook
    var children: [NoteEntry] { folder.children.filter { $0.isFolder && !Notebook.contains(source, $0.url) } }
    var body: some View {
        if !Notebook.contains(source, folder.url) {
            Menu(folder.name) {
                Button("Move here") { notebook.moveItem(source, into: folder.url) }
                    .disabled(source.deletingLastPathComponent().path == folder.url.path)
                if !children.isEmpty {
                    Divider()
                    ForEach(children) { child in FolderDestinationMenu(folder: child, source: source, notebook: notebook) }
                }
            }
        }
    }
}

