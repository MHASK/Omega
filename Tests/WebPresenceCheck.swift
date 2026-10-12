import AppKit
import WebKit

final class PresenceTestFiles: NSObject, WKURLSchemeHandler {
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
@MainActor final class PresenceCheck: NSObject, WKScriptMessageHandler {
    var views: [WKWebView] = [], windows: [NSWindow] = [], sockets: [Int:URLSessionWebSocketTask] = [:]
    var loaded=0, done=false, failed=false, joins: Set<Int>=[], checkpoints: [Int:[String:Any]] = [:]
    var messages: [String]=[], relay: Process?, endpoint="", token="", page="presence-"+UUID().uuidString+".md"
    let publicRelay = ProcessInfo.processInfo.environment["OMEGA_PRESENCE_PUBLIC"] == "1"
    func start(_ root: URL) throws {
        _ = NSApplication.shared
        if publicRelay {
            endpoint="wss://omega.naridon.com/live"
            let p=Process(),out=Pipe();p.executableURL=URL(fileURLWithPath:"/opt/homebrew/bin/gh");p.arguments=["auth","token","--hostname","github.com"];p.standardOutput=out;p.standardError=FileHandle.nullDevice;try p.run();token=String(decoding:out.fileHandleForReading.readDataToEndOfFile(),as:UTF8.self).trimmingCharacters(in:.whitespacesAndNewlines);p.waitUntilExit();guard p.terminationStatus==0 else {throw NSError(domain:"CLI login",code:1)}
        } else {
            let p=Process(),out=Pipe(),node=ProcessInfo.processInfo.environment["OMEGA_NODE"];p.executableURL=URL(fileURLWithPath:node ?? "/usr/bin/env");p.arguments=(node == nil ? ["node"]:[])+[ProcessInfo.processInfo.environment["OMEGA_PRESENCE_RELAY"] ?? root.deletingLastPathComponent().appendingPathComponent("Tests/PresenceRelay.mjs").path];p.standardOutput=out;try p.run();relay=p
            let port=String(decoding:out.fileHandleForReading.availableData,as:UTF8.self).trimmingCharacters(in:.whitespacesAndNewlines);guard let number=Int(port),(1...65535).contains(number) else{throw NSError(domain:"Could not start the local test relay",code:1)};endpoint="ws://127.0.0.1:"+port+"/live"
        }
        for _ in 0..<3 {
            let config=WKWebViewConfiguration();config.websiteDataStore = .nonPersistent();config.setURLSchemeHandler(PresenceTestFiles(root),forURLScheme:"folio");config.userContentController.add(self,name:"folio")
            let view=WKWebView(frame:NSRect(x:0,y:0,width:760,height:580),configuration:config),window=NSWindow(contentRect:NSRect(x:0,y:0,width:760,height:580),styleMask:[.titled],backing:.buffered,defer:false);window.contentView=view
            views.append(view);windows.append(window);view.load(URLRequest(url:URL(string:"folio://app/index.html")!))
        }
    }
    func json(_ object:Any)->String {String(decoding:try! JSONSerialization.data(withJSONObject:object),as:UTF8.self)}
    func deliver(_ i:Int,_ object:[String:Any]) {views[i].evaluateJavaScript("window.folio.liveMessage(\(json(object)))"){_,error in if let error {self.messages.append(error.localizedDescription)}}}
    func send(_ i:Int,_ object:[String:Any]) {sockets[i]?.send(.string(json(object))){_ in}}
    func userContentController(_ c:WKUserContentController,didReceive message:WKScriptMessage){
        guard let b=message.body as? [String:Any],let type=b["type"] as? String,let i=views.firstIndex(where:{$0 === message.webView}) else{return}
        if type=="ready" {loaded+=1;if loaded==3 {Task{await run()}};return}
        if type=="liveConflict" {messages.append("Unexpected document conflict");return}
        if type=="liveReady",let seed=b["state"] as? String {
            let ws=URLSession.shared.webSocketTask(with:URL(string:endpoint)!);sockets[i]=ws;ws.resume()
            send(i,["type":"join","protocol":1,"provider":"github","project":"MHASK/Omega","branch":"main","path":page,"token":publicRelay ? token:["Alice","Bob","Cara"][i],"seed":seed])
            Task{do{while sockets[i]===ws {let m=try await ws.receive();let data:Data;switch m{case .string(let s):data=Data(s.utf8);case .data(let d):data=d;@unknown default:continue};let object=try JSONSerialization.jsonObject(with:data) as! [String:Any];let kind=object["type"] as? String;if kind=="state"{joins.insert(i)};if ["state","update","awareness"].contains(kind ?? ""){deliver(i,object)};if kind=="error"{messages.append(object["message"] as? String ?? "Relay error")}}}catch{if sockets[i]===ws {messages.append("Unexpected disconnect")}}}
        }
        if type=="liveCheckpoint" {checkpoints[i]=b;if b["push"] as? Bool==true {send(i,["type":"update","update":b["update"] ?? b["state"]!,"lineage":b["lineage"]!,"sequence":1])}}
        if type=="liveAwareness" {send(i,["type":"awareness","update":b["update"]!,"lineage":b["lineage"]!])}
    }
    func js(_ i:Int,_ code:String) async throws -> Any? {try await views[i].evaluateJavaScript(code)}
    func settle() async throws {try await Task.sleep(nanoseconds:350_000_000)}
    func check(_ yes:Bool,_ label:String) throws {guard yes else {throw NSError(domain:label+" "+messages.joined(separator:"; "),code:1)};print("PASS:",label)}
    func waitFor(_ label:String,_ condition:() async throws->Bool) async throws {for _ in 0..<30 {if try await condition(){return};try await settle()};throw NSError(domain:label+" "+messages.joined(separator:"; "),code:1)}
    func load(_ i:Int,_ text:String) async throws {_ = try await js(i,"window.folio.load(\(json(["id":"presence","text":text,"theme":"dark"])));true");try await settle()}
    func join(_ i:Int) async throws {joins.remove(i);_ = try await js(i,"window.folio.liveStart({id:'presence'})");try await waitFor("join"){self.joins.contains(i)};try await settle()}
    func text(_ i:Int) async throws->String {try await js(i,"window.folio.snapshot().text") as! String}
    func select(_ i:Int,_ start:Int,_ end:Int) async throws {
        _ = try await js(i,"(()=>{const e=document.querySelector('#editor .tiptap'),p=e.querySelector('p');e.focus();const point=offset=>{const w=document.createTreeWalker(p,NodeFilter.SHOW_TEXT,{acceptNode:n=>n.parentElement.closest('.live-caret')?NodeFilter.FILTER_REJECT:NodeFilter.FILTER_ACCEPT});let n,last;while(n=w.nextNode()){last=n;if(offset<=n.length)return [n,offset];offset-=n.length;}return [last,last.length];};const a=point(\(start)),b=point(\(end)),r=document.createRange();r.setStart(...a);r.setEnd(...b);const s=window.getSelection();s.removeAllRanges();s.addRange(r);document.dispatchEvent(new Event('selectionchange'));return true})()");try await settle()
    }
    func count(_ i:Int,_ selector:String) async throws->Int {try await js(i,"document.querySelectorAll(\(json([selector]))[0]).length") as! Int}
    func close(_ i:Int){let ws=sockets.removeValue(forKey:i);ws?.cancel(with:.goingAway,reason:nil);deliver(i,["type":"offline"])}
    func screenshot(_ i:Int,_ name:String) async throws {
        guard let folder=ProcessInfo.processInfo.environment["OMEGA_PRESENCE_SHOTS"] else{return}
        let image=try await views[i].takeSnapshot(configuration:nil)
        if let tiff=image.tiffRepresentation,let rep=NSBitmapImageRep(data:tiff),let data=rep.representation(using:.png,properties:[:]){try data.write(to:URL(fileURLWithPath:folder).appendingPathComponent(name+".png"))}
    }
    func run() async {
        do {
            let note="# A little room to think\n\nA quiet place for shared ideas.\n\nWrite together, at your own pace.\n"
            for i in 0..<3 {try await load(i,note);try await join(i)}
            try await select(0,2,13)
            try await waitFor("remote rich selection"){let selections=try await self.count(2,".live-selection");let carets=try await self.count(2,".live-caret");return selections>0 && carets==1}
            try check(try await js(2,"document.querySelector('.live-selection').textContent") as? String=="quiet place","remote selection highlights the exact selected words")
            try await select(1,19,19)
            try await waitFor("two named cursors"){try await self.count(2,".live-caret")==2}
            let names=try await js(2,"Array.from(document.querySelectorAll('.live-caret-name')).map(e=>e.textContent)") as! [String]
            try check(publicRelay ? names.allSatisfy{$0=="MHASK"}:Set(names)==Set(["Alice","Bob"]),"three real WebKit editors render two authenticated collaborator cursors")
            try await screenshot(2,"live-cursors-dark")
            let before=try await text(2),state=checkpoints[0]?["state"] as? String
            try await select(0,5,5);try check(try await text(2)==before && checkpoints[0]?["state"] as? String==state,"moving a cursor changes neither Markdown nor its saved CRDT checkpoint")
            try await select(0,0,0)
            _ = try await js(0,"document.execCommand('insertText',false,'Our ');true");try await settle()
            try check(try await text(1).contains("Our A quiet place"),"typing and remote cursor rendering work together")
            try check(try await count(2,".live-caret")==2,"both cursors remain visible after a concurrent text insertion")
            let caretOffset=try await js(2,"(()=>{const p=document.querySelector('#editor .tiptap p'),c=[...p.querySelectorAll('.live-caret')].at(-1),r=document.createRange();r.setStart(p,0);r.setEndBefore(c);const x=document.createElement('div');x.append(r.cloneContents());x.querySelectorAll('.live-caret').forEach(n=>n.remove());return x.textContent.length})()") as! Int
            try check(caretOffset==23,"a collaborator’s cursor follows its original text when another person inserts before it")
            _ = try await js(2,"window.folio.configure({theme:'light',zoom:1});true");try await screenshot(2,"live-cursors-light")
            close(1);try await waitFor("departed cursor removed"){try await self.count(2,".live-caret")==1}
            try check(true,"leaving removes only that participant’s cursor")
            deliver(2,["type":"offline"]);try await waitFor("offline clears cursors"){try await self.count(2,".live-caret")==0}
            try check(true,"losing the connection clears stale remote cursors immediately")
            for i in 0..<3 {close(i);_ = try await js(i,"window.folio.liveStop();true")}
            page="source-"+UUID().uuidString+".md"
            let source="---\ntitle: Shared source\n---\nA quiet place."
            for i in 0..<2 {try await load(i,source);try await join(i)}
            _ = try await js(0,"(()=>{const s=document.querySelector('#source');s.focus();s.setSelectionRange(4,9);s.dispatchEvent(new Event('select'));document.dispatchEvent(new Event('selectionchange'));return true})()");try await settle()
            try await waitFor("source caret"){try await self.count(1,".live-text-caret")==1}
            try check(try await js(1,"document.querySelector('.live-selection').textContent") as? String=="title","source Markdown has a correctly placed caret and selection")
            try await screenshot(1,"live-cursors-source")
            _ = try await js(1,"(()=>{const s=document.getElementById('source');s.focus();s.setSelectionRange(0,0);document.execCommand('insertText',false,'Shared ');return true})()");try await settle()
            try check(try await js(0,"document.getElementById('source').selectionStart") as? Int==11,"source selection stays anchored when a peer inserts text before it")
            _ = try await js(0,"(()=>{const s=document.getElementById('source');s.focus();s.setSelectionRange(11,16,'backward');document.dispatchEvent(new Event('selectionchange'));return true})()");try await settle()
            try check(try await js(1,"document.querySelector('.live-text-caret').dataset.offset") as? String=="11","backward selections put the collaborator’s caret at the correct end")
            for i in 0..<2 {close(i);_ = try await js(i,"window.folio.liveStop();true")}
            page="tasks-"+UUID().uuidString+".md"
            let tasks="<!-- folio:tasks -->\n# Shared plan\n\n## Goals\n\n## To do\n\n- [ ] A task\n  <!-- folio:task {\"id\":\"task\",\"description\":\"A quiet description\"} -->\n\n## In progress\n\n## Done\n"
            for i in 0..<2 {try await load(i,tasks);try await join(i)}
            _ = try await js(0,"(()=>{const s=document.querySelector('.tasks-title');s.focus();s.setSelectionRange(2,6);document.dispatchEvent(new Event('selectionchange'));return true})()");try await settle()
            try await waitFor("task title cursor"){try await self.count(1,".live-text-caret")==1}
            try check(try await js(1,"document.querySelector('.live-selection').textContent") as? String=="ared","task page titles show exact remote selections")
            for i in 0..<2 {_ = try await js(i,"window.folio.revealItem({id:'presence',item:'task',kind:'task'});true")}
            _ = try await js(0,"document.querySelector('.task-description .tiptap').focus();true");try await settle()
            try await waitFor("task description presence"){try await self.count(1,".live-field-presence")==1}
            try check(try await js(1,"document.querySelector('.live-field-presence').textContent") as? String==(publicRelay ? "MHASK editing":"Alice editing"),"task descriptions identify who is editing that field")
            try check(messages.isEmpty,"relay transport and JavaScript report no errors")
            print("All live presence checks passed using",publicRelay ? "the deployed TLS relay":"a real loopback WebSocket relay")
        }catch{print("FAIL:",error);failed=true}
        for i in 0..<3 {close(i)};relay?.terminate();done=true
    }
}
@main struct Main {
    @MainActor static func main(){let t=PresenceCheck();do{try t.start(URL(fileURLWithPath:CommandLine.arguments[1]))}catch{print(error);exit(1)};let deadline=Date().addingTimeInterval(100);while !t.done && Date()<deadline{RunLoop.current.run(until:Date().addingTimeInterval(0.03))};t.relay?.terminate();exit(t.done && !t.failed ? 0 : 1)}
}
