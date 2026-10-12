import AppKit
import SwiftUI
import WebKit

@main struct LayoutCheck {
    @MainActor static func main() {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        Task { @MainActor in
            do { try await run(); print("PASS responsive layout matrix"); exit(0) }
            catch { print("FAIL", error); exit(1) }
        }
        NSApp.run()
    }
    struct Failure: Error, CustomStringConvertible { let description: String }
    @MainActor static func require(_ ok: Bool, _ message: String) throws { if !ok { throw Failure(description: message) } }
    @MainActor static func settle(_ ms: Int = 180) async { try? await Task.sleep(for: .milliseconds(ms)) }
    @MainActor static func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap { descendants($0) } }
    @MainActor static func run() async throws {
        let dir = URL(fileURLWithPath: CommandLine.arguments[1])
        let notes = dir.appendingPathComponent("Notebook")
        try FileManager.default.createDirectory(at: notes, withIntermediateDirectories: true)
        let file = notes.appendingPathComponent("A very long note title that stays inside the footer.md")
        let markdown = """
        # A room for your ideas

        Writing should stay comfortable at every window size. This sentence wraps naturally without cropping either side. Supercalifragilisticexpialidociousandaverylongword.

        | Name | Details | Status | Date | Owner |
        | --- | --- | --- | --- | --- |
        | A wide table | All columns remain reachable | In progress | Monday | Alex |

        > A nested quote stays within the text column.

        ```swift
        let anExtremelyLongLineOfCodeThatMustScrollLocally = "The document itself should never overflow its window."
        ```
        """
        try markdown.write(to: file, atomically: true, encoding: .utf8)
        for i in 1...8 { try "# Note \(i)\n\nSome matching text".write(to: notes.appendingPathComponent("Note \(i).md"), atomically: true, encoding: .utf8) }
        let notebook = Notebook(recovery: DraftRecovery(directory: dir.appendingPathComponent("Recovery")))
        notebook.root = notes; notebook.notebooks = [notes]; notebook.appearance = "dark"
        notebook.entries = try NoteFiles.scan(notes); notebook.trees[notes] = notebook.entries
        notebook.select(file); notebook.sidebarWidth = 260
        OpusIcons.register()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 700), styleMask: [.titled, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        window.titleVisibility = .hidden; window.titlebarAppearsTransparent = true
        let host = NSHostingView(rootView: FolioView(notebook: notebook))
        host.sizingOptions = []; host.safeAreaRegions = []; host.autoresizingMask = [.width, .height]
        window.contentView = host
        window.orderBack(nil)
        for _ in 0..<60 {
            if notebook.richEditor?.ready == true { break }
            await settle(100)
        }
        try require(notebook.richEditor?.ready == true, "Editor never loaded")
        for zoom in [0.7, 1.4, 2.5] {
            notebook.zoom = zoom
            for (w, h) in [(360.0,320.0),(420,760),(600,400),(800,600),(1200,800),(1680,1050)] {
                for sidebar in [false,true] {
                    notebook.sidebar = sidebar
                    window.setContentSize(NSSize(width: w, height: h))
                    host.layoutSubtreeIfNeeded(); await settle()
                    guard let web = notebook.richEditor?.webView else { throw Failure(description: "Editor missing") }
                    let rect = web.convert(web.bounds, to: host)
                    try require(rect.minX >= -1 && rect.maxX <= host.bounds.width + 1 && rect.width > 90 && rect.minY >= -1 && rect.maxY <= host.bounds.height+1, "Native pane clipped: \(w)x\(h) zoom\(zoom) sidebar\(sidebar): \(rect) host\(host.bounds)")
                    let data = try await web.evaluateJavaScript("""
                    (() => { const r=s=>{let b=document.querySelector(s).getBoundingClientRect();return {x:b.x,right:b.right,width:b.width}};
                    return {width:innerWidth,scroll:document.querySelector('#scroller').scrollWidth,prose:r('.tiptap>p'),table:r('.tableWrapper'),heading:r('.tiptap>h1'),text:window.folio.snapshot().text}; })()
                    """) as! [String: Any]
                    let viewport = data["width"] as! Double, scroll = data["scroll"] as! Double
                    let prose = data["prose"] as! [String: Double], table = data["table"] as! [String: Double]
                    try require(abs(viewport - rect.width / zoom) < 2, "Web viewport ignores native bounds")
                    try require(scroll <= viewport+1 && prose["x"]! >= 0 && prose["right"]! <= viewport+1 && prose["width"]! <= 651 && table["x"]! >= 0 && table["right"]! <= viewport+1, "Document overflow at \(w) zoom\(zoom): \(data)")
                    try require(data["text"] as? String == markdown, "Resizing changed note text")
                    if notebook.compactLayout {
                        notebook.toggleSidebar(); await settle()
                        try require(notebook.sidebarOverlay && notebook.sidebarIsVisible, "Compact toggle didn't open")
                        notebook.select(file); await settle()
                        try require(!notebook.sidebarOverlay && notebook.sidebar == sidebar, "Compact selection changed saved sidebar preference")
                    }
                    print("PASS \(Int(w))×\(Int(h)) zoom\(zoom) sidebar\(sidebar), editor \(Int(rect.width))px, prose \(Int(prose["width"]!))px")
                }
            }
        }
        // The smallest viewport at the largest zoom catches inflexible search fields.
        window.setContentSize(NSSize(width: 360, height: 320)); notebook.zoom = 2.5
        notebook.searching = true; await settle(700)
        let fields = descendants(host).compactMap { $0 as? PaletteSearchField.Field }
        try require(fields.count == 1, "Search field not found")
        let field = fields[0], rect = field.convert(field.bounds, to: host)
        try require(rect.width >= 30 && rect.minX >= 0 && rect.maxX <= host.bounds.width && rect.minY >= 0 && rect.maxY <= host.bounds.height, "Search input clipped: \(rect)")
        notebook.searching = false; await settle()
        let web = notebook.richEditor!.webView!
        _ = try await web.evaluateJavaScript("window.folio.command('find')")
        let find = try await web.evaluateJavaScript("(()=>{let r=document.querySelector('#find').getBoundingClientRect();return {left:r.left,right:r.right,width:innerWidth}})()") as! [String: Double]
        try require(find["left"]! >= 0 && find["right"]! <= find["width"]!, "Find bar clipped: \(find)")
        _ = try await web.evaluateJavaScript("window.folio.command('source')")
        let source = try await web.evaluateJavaScript("(()=>{let r=document.querySelector('#source').getBoundingClientRect();return {left:r.left,right:r.right,width:innerWidth,text:window.folio.snapshot().text}})()") as! [String: Any]
        try require((source["left"] as! Double) >= 0 && (source["right"] as! Double) <= (source["width"] as! Double) && source["text"] as? String == markdown, "Source view clipped or changed")
        notebook.fullscreen = true; await settle()
        try require(notebook.sidebar == true, "Resizing lost sidebar preference")
        print("PASS search, find, source mode, temporary sidebar, note integrity")
        let taskFile = notes.appendingPathComponent("Tasks.md")
        let taskText = TaskDocument(title: "A full-width task header").markdown
        try taskText.write(to: taskFile, atomically: true, encoding: .utf8)
        notebook.select(taskFile); await settle(400)
        for (w, h, zoom, sidebar) in [(1200.0,800.0,1.4,true),(1680,1050,2.5,true),(800,600,1.4,false),(360,320,2.5,true)] {
            notebook.zoom = zoom; notebook.sidebar = sidebar
            window.setContentSize(NSSize(width: w, height: h)); host.layoutSubtreeIfNeeded(); await settle(300)
            let taskWeb = notebook.richEditor!.webView!, bounds = taskWeb.convert(taskWeb.bounds, to: host)
            let docked = sidebar && !notebook.compactLayout
            let expectedHeight = host.bounds.height - min(36 * zoom, 52) - (docked ? 0 : min(40 * zoom, 56))
            try require(abs(bounds.height - expectedHeight) < 2, "Task header has a blank native inset: \(bounds)")
            let fits = try await taskWeb.evaluateJavaScript("(()=>{let h=document.querySelector('.tasks-header').getBoundingClientRect(),p=document.querySelector('#task-page');return Math.abs(h.left)<1&&Math.abs(h.right-innerWidth)<2&&p.scrollWidth<=p.clientWidth+1})()") as? Bool
            try require(fits == true, "Task header doesn't fit the native pane")
            try require(notebook.text == taskText, "Header layout changed tasks")
        }
        print("PASS task header fills native pane and respects compact window controls")
        window.orderOut(nil)
    }
}
