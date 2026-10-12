import Foundation
import AppKit
import WebKit

final class ResourceFiles: NSObject, WKURLSchemeHandler {
    let root: URL
    init(_ root: URL) { self.root = root }
    func webView(_ webView: WKWebView, start task: WKURLSchemeTask) {
        do {
            let url = task.request.url!, file = root.appendingPathComponent(String(url.path.dropFirst()))
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
    func load(_ text:String,_ identity:String) async throws {
        id=identity;current=text;try history.observe(text,at:file)
        let data=try JSONSerialization.data(withJSONObject:["id":id,"text":text,"theme":"dark","zoom":1.4])
        _ = try await js("window.folio.load(\(String(decoding:data,as:UTF8.self)))")
        try await settle()
    }
    func run() async {
        do {
            let text = "# A simple table\n\n| Name | Status |\n| --- | --- |\n| First | Ready |\n| Second | Waiting |\n"
            try await load(text,"table-controls")
            _ = try await js("window.errors=[];window.onerror=(m)=>window.errors.push(m);true")
            _ = try await js("document.querySelector('td').dispatchEvent(new PointerEvent('pointermove',{bubbles:true,clientX:200,clientY:200}));true")
            try await assertJS("!document.querySelector('#table-add-row').hidden && !document.querySelector('#table-add-column').hidden", "hover reveals edge controls")
            _ = try await js("document.querySelector('#table-add-row').click();true")
            try await settle()
            try await assertJS("document.querySelector('table').rows.length===4", "bottom plus appends a row")
            try await assertJS("!document.querySelector('#table-tools').hidden", "table toolbar is visible while editing")
            _ = try await js("document.querySelector('#table-add-column').click();true")
            try await settle()
            try await assertJS("document.querySelector('table').rows[0].cells.length===3", "right plus appends a column")
            let beforeRemove=current
            _ = try await js("let c=document.querySelector('#table-columns');c.value='deleteColumn';c.dispatchEvent(new Event('change'));true")
            try await settle()
            try await assertJS("document.querySelector('table').rows[0].cells.length===2", "column menu removes the current column")
            _ = try await js("window.folio.command('undo');true")
            try await settle()
            guard current==beforeRemove else {throw UndoHistory.Failure(message:"Native undo did not restore the removed column")}
            print("PASS: native persistent undo restores removed column exactly")
            _ = try await js("let r=document.querySelector('#table-rows');r.value='deleteRow';r.dispatchEvent(new Event('change'));true")
            try await settle()
            try await assertJS("document.querySelector('table').rows.length===3", "row menu removes the current row")
            _ = try await js("window.folio.command('undo');true")
            try await settle()
            guard current==beforeRemove else {throw UndoHistory.Failure(message:"Native undo did not restore the removed row")}
            print("PASS: native persistent undo restores removed row exactly")
            for (width,zoom) in [(1100.0,1.4),(360.0,1.4),(360.0,2.5)] {
                view.frame.size.width=width;view.pageZoom=zoom
                try await settle()
                _ = try await js("document.querySelector('td').dispatchEvent(new PointerEvent('pointermove',{bubbles:true}));true")
                try await assertJS("[...document.querySelectorAll('.table-edge')].filter(e=>!e.hidden).every(e=>{let r=e.getBoundingClientRect();return r.left>=0&&r.right<=innerWidth&&r.top>=0&&r.bottom<=innerHeight})", "edge controls stay inside viewport at width \(width), zoom \(zoom)")
            }
            let wideText = "# Wide table\n\nProse stays readable.\n\n| " + (1...18).map { "Column \($0)" }.joined(separator: " | ") + " |\n| " + Array(repeating: "---", count:18).joined(separator: " | ") + " |\n| " + Array(repeating:"Content",count:18).joined(separator: " | ") + " |\n"
            for (width,zoom) in [(1600.0,1.0),(1100.0,1.4),(360.0,2.5)] {
                view.frame.size.width=width;view.pageZoom=zoom
                try await load(wideText,"wide-table")
                try await assertJS("(()=>{const w=document.querySelector('.tableWrapper'),r=w.getBoundingClientRect(),s=document.querySelector('#scroller'),p=document.querySelector('.tiptap>p').getBoundingClientRect();return r.left>=4&&r.left<=20&&s.clientWidth-r.right>=4&&s.clientWidth-r.right<=20&&s.scrollWidth<=s.clientWidth+1&&p.width<=651&&w.scrollWidth>w.clientWidth})()", "full-pane table and internal overflow at width \(width), zoom \(zoom)")
                try await assertJS("(()=>{const w=document.querySelector('.tableWrapper');w.scrollLeft=w.scrollWidth;return w.scrollLeft>0&&window.folio.snapshot().text===\(String(decoding: try JSONSerialization.data(withJSONObject:[wideText]),as:UTF8.self))[0]})()", "horizontal scrolling preserves Markdown")
            }
            print("All bundled table control checks passed.")
        }catch{print("FAIL",error);failed=true}
        done=true;try? FileManager.default.removeItem(at:root)
    }

}
@main struct Main {
    @MainActor static func main() {
        let test=Check();test.start(URL(fileURLWithPath:CommandLine.arguments[1]))
        let deadline=Date().addingTimeInterval(45)
        while !test.done && Date()<deadline {RunLoop.current.run(until:Date().addingTimeInterval(0.03))}
        exit(test.done && !test.failed ? 0 : 1)
    }
}
