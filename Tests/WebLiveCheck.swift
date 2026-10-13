import AppKit
import WebKit

final class LiveTestFiles: NSObject, WKURLSchemeHandler {
    let root: URL
    init(_ root: URL) { self.root = root }
    func webView(_ webView: WKWebView, start task: WKURLSchemeTask) {
        do {
            let file = root.appendingPathComponent(String(task.request.url!.path.dropFirst()))
            let data = try Data(contentsOf: file)
            let mime = ["js":"text/javascript","css":"text/css","html":"text/html","woff2":"font/woff2","ttf":"font/ttf"][file.pathExtension] ?? "application/octet-stream"
            task.didReceive(URLResponse(url: task.request.url!, mimeType: mime, expectedContentLength: data.count, textEncodingName: "utf-8")); task.didReceive(data); task.didFinish()
        } catch { task.didFailWithError(error) }
    }
    func webView(_ webView: WKWebView, stop task: WKURLSchemeTask) {}
}
@MainActor final class LiveWebCheck: NSObject, WKScriptMessageHandler {
    var views: [WKWebView] = [], windows: [NSWindow] = [], loaded = 0, done = false, failed = false, sharing = true
    var state = "", checkpoints: [Int: [String:Any]] = [:], conflicts = 0
    func start(_ root: URL) {
        _ = NSApplication.shared
        for _ in 0..<2 {
            let config = WKWebViewConfiguration(); config.websiteDataStore = .nonPersistent(); config.setURLSchemeHandler(LiveTestFiles(root), forURLScheme: "folio"); config.userContentController.add(self, name:"folio")
            let view = WKWebView(frame:NSRect(x:0,y:0,width:950,height:700),configuration:config)
            let window = NSWindow(contentRect:view.frame,styleMask:[.titled],backing:.buffered,defer:false);window.contentView=view
            views.append(view); windows.append(window);view.load(URLRequest(url:URL(string:"folio://app/index.html")!))
        }
    }
    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body=message.body as? [String:Any],let type=body["type"] as? String,let index=views.firstIndex(where: {$0 === message.webView}) else {return}
        if type=="ready" {loaded+=1;if loaded==2 {Task {await run()}};return}
        if type=="liveConflict" { conflicts+=1; return }
        if type=="liveReady",let seed=body["state"] as? String {
            let created=state.isEmpty;if created {state=seed};deliver(index,["type":"state","state":state,"created":created]);return
        }
        if type=="liveCheckpoint",let value=body["state"] as? String {
            checkpoints[index]=body
            if sharing && body["push"] as? Bool == true {state=value;deliver(1-index,["type":"update","update":body["update"] as? String ?? value])}
        }
    }
    func deliver(_ i:Int,_ message:[String:Any]) {views[i].evaluateJavaScript("window.folio.liveMessage(\(json(message)))",completionHandler:nil)}
    func json(_ value:Any)->String {String(decoding:try! JSONSerialization.data(withJSONObject:value),as:UTF8.self)}
    func js(_ i:Int,_ code:String) async throws -> Any? {try await views[i].evaluateJavaScript(code)}
    func settle() async throws {try await Task.sleep(nanoseconds:220_000_000)}
    func text(_ i:Int) async throws -> String {try await js(i,"window.folio.snapshot().text") as! String}
    func check(_ value:Bool,_ name:String) throws {if !value {throw NSError(domain:name,code:1)};print("PASS:",name)}
    func load(_ i:Int,_ text:String) async throws {_ = try await js(i,"window.folio.load(\(json(["id":"live","text":text,"theme":"dark"])));true");try await settle()}
    func join(_ i:Int,_ checkpoint:[String:Any]?=nil) async throws {
        var config:[String:Any]=["id":"live"];if let checkpoint {config["state"]=checkpoint["state"];config["accepted"]=true}
        _ = try await js(i,"window.folio.liveStart(\(json(config)))");try await settle()
    }
    func append(_ i:Int,_ word:String) async throws {
        _ = try await js(i,"(()=>{let e=document.querySelector('#editor .tiptap');e.focus();let r=document.createRange();r.selectNodeContents(e.lastChild);r.collapse(false);let s=window.getSelection();s.removeAllRanges();s.addRange(r);document.execCommand('insertText',false,\(json([word]))[0]);return true})()")
        try await settle()
    }
    func run() async {
        do {
            let note="# Shared page\n\nA quiet place.\n"
            try await load(0,note);try await load(1,note);try await join(0);try await join(1)
            try check(conflicts==0,"equal cold clients adopt a single shared seed")
            sharing=false;try await append(0," Alice");try await append(1," Bob")
            let ca=checkpoints[0]!,cb=checkpoints[1]!;sharing=true
            deliver(0,["type":"update","update":cb["state"]!]);deliver(1,["type":"update","update":ca["state"]!]);try await settle()
            let a=try await text(0),b=try await text(1);try check(a==b && a.contains("Alice") && a.contains("Bob"),"two actual WebKit editors converge after simultaneous offline rich-text edits")
            _ = try await js(0,"window.folio.command('undo');true");try await settle()
            let undone=try await text(1);try check(!undone.contains("Alice") && undone.contains("Bob"),"shared undo removes only the local author's edit")
            let request:[String:Any]=["id":"live","expected":undone,"text":undone+"\nAn assistant joined.\n"]
            let replaced=try await js(0,"window.folio.replaceForAssistant(\(json(request)))") as? Bool
            try check(replaced==true,"assistant can patch a live rich note atomically");try await settle()
            try check(try await text(1).contains("An assistant joined."),"assistant edits arrive in the other live editor")
            let saved=checkpoints[0]!;try await load(0,try await text(0));try await join(0,saved);try check(try await text(0)==text(1),"cached shared state reopens without duplicate content")
            // A local file changed while its editor was closed. Import that diff
            // into the cached shared baseline, then merge with the live room.
            let offlineCache=checkpoints[0]!,offlineText=(try await text(0))+"\nFrom disk.\n"
            try await load(0,offlineText)
            _ = try await js(0,"window.folio.liveStart(\(json(["id":"live","state":offlineCache["state"]!,"accepted":true,"externalText":offlineText])))")
            try await settle();try check(try await text(1).contains("From disk."),"external file edits import into cached shared state")
            // With no server history, reconnect from each Mac's saved Git checkpoint.
            sharing=false
            try await append(0," Offline A");try await append(1," Offline B")
            let offlineA=checkpoints[0]!,offlineB=checkpoints[1]!,textA=try await text(0),textB=try await text(1)
            _ = try await js(0,"window.folio.liveStop();true");_ = try await js(1,"window.folio.liveStop();true")
            state="";sharing=true
            try await load(0,textA);try await load(1,textB);try await join(0,offlineA);try await join(1,offlineB)
            let recovered=try await text(0),recoveredPeer=try await text(1)
            try check(recovered == recoveredPeer && recovered.contains("Offline A") && recovered.contains("Offline B"),"empty relay recovers concurrent offline edits entirely from client checkpoints")
            // A Git fetch returns a snapshot while both live editors keep typing.
            sharing=false
            try await append(0," Git local");try await append(1," Git incoming")
            let gitLocal=checkpoints[0]!,gitRemote=checkpoints[1]!
            let gitMerged=try await js(0,"window.folio.mergeGitCheckpoints(\(json(["mine":gitLocal,"incoming":gitRemote])))") as! [String:Any]
            try await append(0," Still typing")
            let applied=try await js(0,"window.folio.gitApply(\(json(["id":"live","checkpoint":gitMerged,"expected":"outdated snapshot","text":gitMerged["text"]!])))") as? [String:Any]
            try check(applied != nil,"Git checkpoint imports without stopping the live session")
            let gitText=try await text(0)
            try check(gitText.contains("Git local") && gitText.contains("Git incoming") && gitText.contains("Still typing"),"typing after the Git snapshot survives the incoming merge")
            let stable=try await js(0,"window.folio.gitApply(\(json(["id":"live","checkpoint":gitMerged,"expected":"old","text":gitMerged["text"]!])))") as? [String:Any]
            try check(stable?["text"] as? String == gitText,"repeated Git checkpoint import is idempotent in WebKit")
            sharing=true;deliver(1,["type":"update","update":checkpoints[0]!["state"]!]);try await settle()
            try check(try await text(0)==text(1),"Git changes propagate to the other editor without leaving live editing")
            _ = try await js(0,"window.folio.command('undo');true");try await settle()
            try check(try await text(0).contains("Git incoming"),"local undo after Git sync retains the remote edit")
            let oldBaseline=checkpoints[1]!
            // A fresh independently seeded client arrives first after the relay empties.
            _ = try await js(0,"window.folio.liveStop();true");_ = try await js(1,"window.folio.liveStop();true")
            state=""
            try await load(0,"# Independently changed\n\nA different Git baseline.\n");try await join(0)
            let latestRecovered=try await text(1)
            try await load(1,latestRecovered);try await join(1,oldBaseline)
            let preserved=try await text(1)
            try check(conflicts==1 && preserved==latestRecovered,"a returning client never merges an unrelated seed after relay restart")
            _ = try await js(1,"window.folio.liveAccept();true");try await settle()
            try check(try await text(0)==text(1),"explicit adoption remains safe across different stored baselines")
            conflicts=0
            state="";checkpoints=[:]
            let tasks="<!-- folio:tasks -->\n# Plan\n\n## Goals\n\n## To do\n\n- [ ] A task\n  <!-- folio:task {\"id\":\"task\",\"description\":\"Description\"} -->\n\n## In progress\n\n## Done\n"
            try await load(0,tasks);try await load(1,tasks);try await join(0);try await join(1)
            try check(conflicts==0,"task pages adopt a single shared seed")
            sharing=false
            _ = try await js(0,"(()=>{let e=document.querySelector('.tasks-title');e.value='A shared plan';e.dispatchEvent(new Event('input'));return true})()");try await settle()
            _ = try await js(1,"document.querySelector('[aria-label=\"Complete task\"]').click();true");try await settle()
            let ta=checkpoints[0]!,tb=checkpoints[1]!;sharing=true
            deliver(0,["type":"update","update":tb["state"]!]);deliver(1,["type":"update","update":ta["state"]!]);try await settle()
            let merged=try await text(0), mergedOther=try await text(1);try check(merged==mergedOther && merged.contains("# A shared plan") && merged.contains("- [x] A task"),"task title and task status merge independently in WebKit")
            _ = try await js(0,"window.folio.command('undo');true");try await settle()
            let taskUndo=try await text(0);try check(taskUndo.contains("# Plan") && taskUndo.contains("- [x] A task"),"task undo retains a peer's completion")
            state="";checkpoints=[:]
            try await load(0,"---\ntitle: Source\n---\nBody");try await load(1,"---\ntitle: Source\n---\nBody");try await join(0);try await join(1)
            _ = try await js(0,"(()=>{let e=document.querySelector('#source');e.value+=' updated';e.dispatchEvent(new Event('input'));return true})()");try await settle()
            try check(try await text(1).hasSuffix("updated"),"extended Markdown source is shared losslessly")
            let originalShared=try await text(0)
            try await load(1,"A completely different local version")
            try await join(1);try check(conflicts==1,"a different cold local file is never silently replaced")
            try check(try await text(1).contains("completely different"),"local version remains visible until a choice")
            _ = try await js(1,"window.folio.liveAccept();true");try await settle()
            try check(try await text(1)==originalShared,"explicit shared-version adoption restores the shared document kind")
            print("All live WebKit checks passed.")
        } catch {print("FAIL:",error);failed=true}
        done=true
    }
}
@main struct Main {
    @MainActor static func main(){let test=LiveWebCheck();test.start(URL(fileURLWithPath:CommandLine.arguments[1]));let deadline=Date().addingTimeInterval(75);while !test.done && Date()<deadline {RunLoop.current.run(until:Date().addingTimeInterval(0.03))};exit(test.done && !test.failed ? 0 : 1)}
}
