import Foundation
import AppKit
import WebKit

final class ResourceFiles: NSObject, WKURLSchemeHandler {
    let root: URL
    init(_ root: URL) { self.root = root }
    func webView(_ webView: WKWebView, start task: WKURLSchemeTask) {
        do {
            let url = task.request.url!, file = root.appendingPathComponent(String(url.path.dropFirst())).standardizedFileURL.resolvingSymlinksInPath()
            guard file.path.hasPrefix(root.standardizedFileURL.resolvingSymlinksInPath().path + "/") else { throw CocoaError(.fileReadNoPermission) }
            let data = try Data(contentsOf: file), types = ["html":"text/html","css":"text/css","js":"text/javascript","ttf":"font/ttf","woff2":"font/woff2"]
            task.didReceive(URLResponse(url: url, mimeType: types[file.pathExtension] ?? "application/octet-stream", expectedContentLength: data.count, textEncodingName: "utf-8"))
            task.didReceive(data); task.didFinish()
        } catch { task.didFailWithError(error) }
    }
    func webView(_ webView: WKWebView, stop task: WKURLSchemeTask) {}
}
@MainActor final class Check: NSObject, WKScriptMessageHandler {
    var view: WKWebView!
    var window: NSWindow!
    var done = false, failed = false, current = "", id = "note-a", commands = 0
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("Folio-WebUndo-" + UUID().uuidString)
    lazy var history = UndoHistory(file: root.appendingPathComponent("undo.sqlite"))
    var file: URL { root.appendingPathComponent(id + ".md") }
    func start(_ resources: URL) {
        _ = NSApplication.shared
        let config = WKWebViewConfiguration(); config.websiteDataStore = .nonPersistent()
        config.setURLSchemeHandler(ResourceFiles(resources), forURLScheme: "folio")
        config.userContentController.add(self, name: "folio")
        view = WKWebView(frame: NSRect(x:0,y:0,width:1100,height:900),configuration:config)
        window = NSWindow(contentRect:view.frame,styleMask:[.titled],backing:.buffered,defer:false); window.contentView=view
        view.load(URLRequest(url:URL(string:"folio://app/index.html")!))
    }
    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body=message.body as? [String:Any],let type=body["type"] as? String else{return}
        if type == "ready" { Task { await run() }; return }
        guard body["id"] as? String == id else{return}
        do {
            if type == "change", let text=body["text"] as? String {
                try history.record(before:current,after:text,at:file,beforeSelection:body["beforeSelection"] as? String ?? "",afterSelection:body["afterSelection"] as? String ?? "",typing:body["typing"] as? Bool ?? false)
                current=text
            }
            if type == "history" {
                if let text=body["text"] as? String,text != current {try history.record(before:current,after:text,at:file);current=text}
                let step=try history.travel(at:file,expected:current,redo:body["redo"] as? Bool ?? false,protect:{_ in})
                var response:[String:Any] = ["id":id]
                if let step {current=step.text;response["text"]=step.text;response["selection"]=step.selection}
                commands += 1
                let data=try JSONSerialization.data(withJSONObject:response)
                view.evaluateJavaScript("window.folio.historyResult(\(String(decoding:data,as:UTF8.self)))",completionHandler:nil)
            }
        } catch { print("BRIDGE FAIL",error);failed=true;done=true }
    }
    func js(_ code:String) async throws -> Any? {
        try await withCheckedThrowingContinuation { continuation in
            view.evaluateJavaScript(code) { value,error in
                if let error{continuation.resume(throwing:error)}else{continuation.resume(returning:value)}
            }
        }
    }
    func assertJS(_ code:String,_ label:String) async throws {
        guard try await js(code) as? Bool == true else {throw UndoHistory.Failure(message:label)}
        print("PASS:",label)
    }
    func settle() async throws { try await Task.sleep(nanoseconds:150_000_000) }
    func snapshot(_ suffix:String) async throws {
        guard CommandLine.arguments.count>2 else{return}
        let image:NSImage=try await withCheckedThrowingContinuation { continuation in
            view.takeSnapshot(with:nil) { image,error in
                if let image {continuation.resume(returning:image)}else{continuation.resume(throwing:error!)}
            }
        }
        let path=CommandLine.arguments[2].replacingOccurrences(of:".png",with:suffix+".png")
        if let tiff=image.tiffRepresentation,let bitmap=NSBitmapImageRep(data:tiff),let png=bitmap.representation(using:.png,properties:[:]) {try png.write(to:URL(fileURLWithPath:path))}
    }
    func load(_ text:String,_ identity:String) async throws {
        id=identity;current=text;try history.observe(text,at:file)
        let data=try JSONSerialization.data(withJSONObject:["id":id,"text":text,"theme":"dark","zoom":1.4])
        _ = try await js("window.folio.load(\(String(decoding:data,as:UTF8.self)))")
        try await settle()
    }
    func wait(_ expression: String) async throws {
        for _ in 0..<300 { if (try? await js(expression)) as? Bool == true { return }; try await Task.sleep(for: .milliseconds(50)) }
        throw UndoHistory.Failure(message: "Timed out: " + expression + "\n" + String(describing: try await js("document.body.innerText")))
    }
    func run() async {
        do {
            let fixture = "# Clear diagrams\n\n```mermaid\nflowchart LR\n  idea[An idea] --> draft[A first draft]\n  draft --> review{Ready to share?}\n  review -->|Yes| publish[Share it]\n  review -->|Not yet| draft\n```\n\nA regular paragraph.\n\n```swift\nlet value = 42\n```\n"
            try await load(fixture, "diagrams")
            try await wait("document.querySelector('.diagram-preview')?.dataset.state==='ready'")
            try await assertJS("document.querySelector('#source').hidden && document.querySelectorAll('.diagram-preview svg').length===1 && document.querySelector('code.language-swift').textContent.includes('42')", "Mermaid renders locally alongside regular code and rich notes")
            try await assertJS("document.querySelectorAll('.diagram-preview foreignObject,.diagram-preview script,.diagram-render-staging').length===0", "preview contains only a passive SVG and cleans up render staging")
            let untouched = try await js("window.folio.snapshot().text") as? String; precondition(untouched == fixture)
            try await snapshot("-dark")
            _ = try await js("document.querySelector('[aria-label=\"Expand diagram\"]').click();document.querySelector('[aria-label=\"Zoom in\"]').click();true")
            try await assertJS("document.querySelector('.diagram-expanded svg') && document.querySelector('.diagram-zoom-value').textContent !== '100%'", "expanded diagrams support fit and zoom")
            _ = try await js("document.dispatchEvent(new KeyboardEvent('keydown',{key:'Escape',bubbles:true}));document.querySelector('[aria-label=\"Edit diagram source\"]').click();true")
            try await assertJS("!document.querySelector('.diagram-expanded') && !document.querySelector('.diagram-input').hidden", "Escape closes the diagram and Source opens the editable Markdown")
            _ = try await js("var input=document.querySelector('.diagram-input');input.value='flowchart LR\\n  A[Keep your ideas] --> B[Make something]';input.dispatchEvent(new Event('input',{bubbles:true}));true")
            try await settle()
            _ = try await js("document.querySelector('[aria-label=\"Preview diagram\"]').click();true")
            try await wait("document.querySelector('.diagram-preview svg')?.textContent.includes('Keep your ideas')")
            try await assertJS("window.folio.snapshot().text.includes('Keep your ideas') && !window.folio.snapshot().text.includes('<svg')", "source editing changes the diagram without storing generated markup")
            _ = try await js("document.querySelector('[aria-label=\"Edit diagram source\"]').click();window.folio.command('undo');true")
            try await wait("window.folio.snapshot().text.includes('Ready to share?')")
            print("PASS: native undo restores diagram source")
            _ = try await js("window.folio.configure({theme:'light',zoom:1});true")
            try await wait("document.querySelector('.diagram-preview svg')?.textContent.includes('#302e34')")
            try await snapshot("-light")
            let kinds = ["sequenceDiagram\n participant You\n participant Team\n You->>Team: Share an idea\n Team-->>You: Feedback", "xychart-beta\n title \"Weekly progress\"\n x-axis [Mon, Tue, Wed]\n y-axis \"Completed\" 0 --> 20\n bar [3, 7, 14]", "pie title Focus\n \"Notes\" : 6\n \"Tasks\" : 4", "mindmap\n root((Ideas))\n  Notes\n  Tasks"]
            for (i, code) in kinds.enumerated() {
                try await load("# Diagram\n\n```mermaid\n" + code + "\n```\n", "kind-\(i)")
                try await wait("document.querySelector('.diagram-preview')?.dataset.state==='ready'")
                print("PASS: diagram family", i)
            }
            try await load("# Still readable\n\n```mermaid\nthis is invalid syntax\n```\n\nThe rest of the note stays here.\n", "invalid")
            try await wait("document.querySelector('.diagram-preview')?.dataset.state==='error'")
            try await assertJS("document.querySelector('#source').hidden && document.querySelector('.tiptap').textContent.includes('The rest of the note') && window.folio.snapshot().text.includes('this is invalid syntax')", "syntax errors stay inside the diagram and preserve all source content")
            try await load("# Safe drawing\n\n```mermaid\nflowchart LR\n A --> B\n click A \"https://example.com\"\n```\n", "external")
            try await wait("document.querySelector('.diagram-preview')?.dataset.state==='error'")
            try await assertJS("!document.querySelector('.diagram-preview a,.diagram-preview img')", "diagram-supplied external resources cannot load")
            if CommandLine.arguments.count > 3 {
                try await load(String(contentsOfFile: CommandLine.arguments[3], encoding: .utf8), "real-diagram")
                try await wait("document.querySelector('.diagram-preview')?.dataset.state==='ready'")
                try await snapshot("-architecture")
                print("PASS: supplied architecture diagram renders in native WebKit")
            }
            print("All diagram WebKit checks passed.")
        } catch { print("FAIL", error); failed=true }
        done=true;try? FileManager.default.removeItem(at:root)
    }
}
@main struct Main {
    @MainActor static func main() {
        let test=Check();test.start(URL(fileURLWithPath:CommandLine.arguments[1]))
        let deadline=Date().addingTimeInterval(90)
        while !test.done && Date()<deadline {RunLoop.current.run(until:Date().addingTimeInterval(0.03))}
        exit(test.done && !test.failed ? 0 : 1)
    }
}
