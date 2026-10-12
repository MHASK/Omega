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
    var pageRequests=0, openedLink=""
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
        if type == "pages" {
            pageRequests += 1
            var pages=[["name":"Café plan", "location":"Other / Drafts", "href":"../Other/Caf%C3%A9%20plan.md"],["name":"Decision log", "location":"Notebook", "href":"./Decision%20log.md"]]
            if body["kind"] as? String == "task" { pages = [["name":"Keep every detail", "kind":"task", "location":"Notebook / Tasks", "href":"./Tasks.md", "reference":"t:0", "revision":"fixture", "current":"false"]] }
            let data=try! JSONSerialization.data(withJSONObject:["id":id,"request":body["request"]!,"pages":pages])
            view.evaluateJavaScript("window.folio.pageResults(\(String(decoding:data,as:UTF8.self)))",completionHandler:nil)
            return
        }
        if type == "prepareItemLink" {
            let response:[String:Any] = ["id":id,"request":body["request"]!,"page":["name":"Keep every detail","href":"./Tasks.md#folio-task-stable-one"]]
            view.evaluateJavaScript("window.folio.linkReady(\(String(decoding:try! JSONSerialization.data(withJSONObject:response),as:UTF8.self)))",completionHandler:nil);return
        }
        if type == "link" {openedLink=body["url"] as? String ?? "";return}
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
            view.pageZoom=1.4
            let text="# Linking notes\n\nBefore and after.\n"
            try await load(text,"page-links")
            _ = try await js("window.folio.command('page');true")
            try await settle()
            try await assertJS("!document.querySelector('#page-picker').hidden && document.querySelectorAll('#page-results button').length===2 && document.activeElement.id==='page-input'", "page picker loads native results and focuses search")
            try await assertJS("!document.querySelector('#page-picker').hidden && document.querySelector('#page-picker').getBoundingClientRect().bottom<=innerHeight", "picker fits the viewport")
            _ = try await js("let i=document.querySelector('#page-input');i.value='decision';i.dispatchEvent(new Event('input'));i.dispatchEvent(new KeyboardEvent('keydown',{key:'Enter',bubbles:true}));true")
            try await settle()
            try await assertJS("!!document.querySelector('a[data-page-link][href=\"./Decision%20log.md\"]')", "keyboard choice inserts a styled relative page link")
            guard current.contains("[Decision log](./Decision%20log.md)") else {throw UndoHistory.Failure(message:"Link Markdown missing")}
            let linked=current
            _ = try await js("document.querySelector('a[data-page-link]').click();true")
            try await settle()
            guard openedLink=="./Decision%20log.md" && current==linked else {throw UndoHistory.Failure(message:"Page click failed or changed content")}
            print("PASS: page click sends relative path without editing content")
            _ = try await js("window.folio.command('undo');true");try await settle()
            guard current==text else {throw UndoHistory.Failure(message:"Link undo did not restore original file")}
            print("PASS: persistent undo restores the original note")
            _ = try await js("window.folio.focus();true");try await settle()
            _ = try await js("(()=>{let p=document.querySelector('.tiptap>p');let r=document.createRange();r.selectNodeContents(p);r.collapse(false);let s=getSelection();s.removeAllRanges();s.addRange(r);document.execCommand('insertText',false,'[[');return true;})()")
            try await settle()
            try await assertJS("!document.querySelector('#page-picker').hidden", "typing double bracket opens the page picker")
            _ = try await js("document.querySelector('#page-input').dispatchEvent(new KeyboardEvent('keydown',{key:'Escape',bubbles:true}));true");try await settle()
            try await assertJS("document.querySelector('#page-picker').hidden && document.querySelector('.tiptap>p').textContent.endsWith('[[')", "Escape preserves typed text and closes the picker")
            for (width,zoom) in [(1100.0,1.4),(360.0,2.5)] {
                view.frame.size.width=width;view.pageZoom=zoom
                try await load("# Links\n\n/page\n","slash-page")
                _ = try await js("window.folio.focus();true");try await settle()
                _ = try await js("(()=>{let p=document.querySelector('.tiptap>p');let r=document.createRange();r.selectNodeContents(p);r.collapse(false);let s=getSelection();s.removeAllRanges();s.addRange(r);return true;})()");try await settle()
                _ = try await js("document.querySelector('.tiptap').dispatchEvent(new KeyboardEvent('keydown',{key:'Enter',bubbles:true,cancelable:true}));true");try await settle()
                try await assertJS("!document.querySelector('#page-picker').hidden", "slash page command opens picker at width \(width)")
                try await assertJS("(()=>{let r=document.querySelector('#page-picker').getBoundingClientRect();return r.left>=0&&r.right<=innerWidth&&r.bottom<=innerHeight})()", "picker stays inside viewport at zoom \(zoom)")
            }
            view.frame.size.width=1000;view.pageZoom=1.4
            try await load("# Links\n\n/task\n","task-links")
            _=try await js("window.folio.focus();(()=>{let p=document.querySelector('.tiptap>p');let r=document.createRange();r.selectNodeContents(p);r.collapse(false);getSelection().removeAllRanges();getSelection().addRange(r);return true})()");try await settle()
            _=try await js("document.querySelector('.tiptap').dispatchEvent(new KeyboardEvent('keydown',{key:'Enter',bubbles:true,cancelable:true}));true");try await settle()
            try await assertJS("document.querySelector('#page-results').textContent.includes('Keep every detail')", "slash task loads task results")
            _=try await js("document.querySelector('#page-input').dispatchEvent(new KeyboardEvent('keydown',{key:'Enter',bubbles:true,cancelable:true}));true");try await settle()
            try await assertJS("!!document.querySelector('a[data-item-link=task]')", "task links wait for stable identity and render a task icon")
            let taskLinked=current
            _=try await js("document.querySelector('a[data-item-link=task]').click();true");try await settle()
            guard openedLink=="./Tasks.md#folio-task-stable-one" && current==taskLinked else {throw UndoHistory.Failure(message:"Task link did not navigate safely")}
            _=try await js("window.folio.command('undo');true");try await settle()
            guard current.contains("/task") && !current.contains("folio-task") else {throw UndoHistory.Failure(message:"Task link undo failed")}
            print("All bundled page-link checks passed.")
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
