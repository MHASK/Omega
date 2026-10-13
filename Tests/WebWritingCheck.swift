import AppKit
import WebKit

final class WritingTestFiles: NSObject, WKURLSchemeHandler {
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
@MainActor final class WritingWebCheck: NSObject, WKScriptMessageHandler {
    var views: [WKWebView] = [], windows: [NSWindow] = [], loaded = 0, done = false, failed = false, sharing = true
    let interactive = CommandLine.arguments.contains("--interactive")
    var state = "", checkpoints: [Int: [String:Any]] = [:], conflicts = 0
    func start(_ root: URL) {
        _ = NSApplication.shared
        for _ in 0..<2 {
            let config = WKWebViewConfiguration(); config.websiteDataStore = .nonPersistent(); config.setURLSchemeHandler(WritingTestFiles(root), forURLScheme: "folio"); config.userContentController.add(self, name:"folio")
            let view = WKWebView(frame:NSRect(x:0,y:0,width:950,height:700),configuration:config)
            let window = NSWindow(contentRect:view.frame,styleMask:[.titled],backing:.buffered,defer:false);window.contentView=view;window.acceptsMouseMovedEvents=true
            views.append(view); windows.append(window);view.load(URLRequest(url:URL(string:"folio://app/index.html")!))
        }
    }
    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body=message.body as? [String:Any],let type=body["type"] as? String,let index=views.firstIndex(where: {$0 === message.webView}) else {return}
        if type=="ready" {loaded+=1;if loaded==2 {Task {
            if interactive {
                try? await load(0,"# Move a little\n\n## Plans for today\n\n- First item\n  - A nested thought\n- Second item\n- Third item\n\nA quiet final paragraph.\n")
                NSApp.setActivationPolicy(.regular);windows[0].title="Omega block drag check";windows[0].setFrameTopLeftPoint(NSPoint(x:0,y:NSScreen.main!.visibleFrame.maxY));windows[0].makeKeyAndOrderFront(nil);NSApp.activate(ignoringOtherApps:true)
            } else {await run()}
        }};return}
        if interactive && type=="change",let text=body["text"] as? String {
            try? text.write(to:URL(fileURLWithPath:CommandLine.arguments[2]).appendingPathComponent("native-drag-result.md"),atomically:true,encoding:.utf8)
        }
        if type=="pages" {let reply:[String:Any]=["id":"live","request":body["request"]!,"pages":[["name":"A linked note","location":"Notebook","href":"./Linked.md"]]];views[index].evaluateJavaScript("window.folio.pageResults(\(json(reply)))",completionHandler:nil);return}
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
    func select(_ i:Int,_ word:String) async throws {
        _ = try await js(i,"""
        (()=>{const e=document.querySelector('#editor .tiptap');e.focus();const walker=document.createTreeWalker(e,NodeFilter.SHOW_TEXT);let n;while(n=walker.nextNode()){const at=n.textContent.indexOf(\(json([word]))[0]);if(at>=0){const r=document.createRange();r.setStart(n,at);r.setEnd(n,at+\(word.utf16.count));const s=window.getSelection();s.removeAllRanges();s.addRange(r);return true;}}throw Error('Text not found')})()
        """);try await settle()
    }
    func click(_ i:Int,_ selector:String) async throws {_ = try await js(i,"document.querySelector(\(json([selector]))[0]).click();true");try await settle()}
    func drag(_ source:String,_ target:String,cancel:Bool=false) async throws {
        _ = try await js(0,"""
        (()=>{
          const source=document.querySelector(\(json([source]))[0]),target=document.querySelector(\(json([target]))[0]);
          const r=source.getBoundingClientRect(),t=target.getBoundingClientRect();
          source.dispatchEvent(new PointerEvent('pointermove',{bubbles:true,clientX:r.left+10,clientY:r.top+5}));
          const h=document.querySelector('.block-tools button:last-child'),b=h.getBoundingClientRect();
          h.dispatchEvent(new PointerEvent('pointerdown',{bubbles:true,cancelable:true,pointerId:17,button:0,clientX:b.left+8,clientY:b.top+8}));
          document.dispatchEvent(new PointerEvent('pointermove',{bubbles:true,cancelable:true,pointerId:17,buttons:1,clientX:t.left+10,clientY:t.bottom-1}));
          window.dragTestPoint={x:t.left+10,y:t.bottom-1};return true;
        })()
        """);try await settle()
        try check(try await js(0,"!document.querySelector('.block-drop-guide').hidden") as! Bool,"drag presents a valid drop marker")
        try await screenshot("writing-block-drag")
        _ = try await js(0,cancel ? "document.dispatchEvent(new KeyboardEvent('keydown',{key:'Escape',bubbles:true,cancelable:true}));true" : "document.dispatchEvent(new PointerEvent('pointerup',{bubbles:true,cancelable:true,pointerId:17,clientX:window.dragTestPoint.x,clientY:window.dragTestPoint.y}));true")
        try await settle()
        try check(try await js(0,"document.querySelector('.block-drop-guide').hidden&&!document.body.classList.contains('block-dragging')&&document.querySelector('.block-menu').hidden") as! Bool,"drop clears drag UI without opening block actions")
    }
    func screenshot(_ name:String) async throws {
        let image=try await views[0].takeSnapshot(configuration:nil)
        if let tiff=image.tiffRepresentation,let png=NSBitmapImageRep(data:tiff)?.representation(using:.png,properties:[:]){try png.write(to:URL(fileURLWithPath:CommandLine.arguments[2]).appendingPathComponent(name+".png"))}
    }
    func run() async {
        do {
            let note="# A little room to write\n\nGood ideas deserve a quiet place.\n\n## The next chapter\n\n- Explore the possibilities\n- Share a thought with the team\n\nA new paragraph.\n"
            try await load(0,note);try await load(1,note)
            let bodySize=try await js(0,"getComputedStyle(document.querySelector('#editor')).fontSize") as! String
            let controlSize=try await js(0,"getComputedStyle(document.querySelector('.note-tools button')).fontSize") as! String
            try await click(0,".note-tools button:last-child");try await click(0,"[aria-label='Larger document text']");try await click(0,"[aria-label='Serif font']")
            try check(try await js(0,"getComputedStyle(document.querySelector('#editor')).fontSize") as! String != bodySize,"document size changes independently")
            try check(try await js(0,"getComputedStyle(document.querySelector('.note-tools button')).fontSize") as! String == controlSize,"menu type size remains unchanged")
            try check(try await text(0)==note,"document appearance never rewrites the local note")
            try await screenshot("writing-appearance");try await click(0,".writing-panel [aria-label=Close]")
            try await select(0,"Good ideas");_ = try await js(0,"window.folio.command('color');true");try await settle();try await screenshot("writing-colors")
            try await click(0,"[aria-label='Blue text']");_ = try await js(0,"window.folio.command('color');true");try await click(0,"[aria-label='Highlight colors']");try await click(0,"[aria-label='Yellow highlight']")
            _ = try await js(0,"window.folio.command('underline');true");try await settle()
            let colored=try await text(0);try check(colored.contains("data-omega-color=\"blue\"") && colored.contains("data-omega-highlight=\"yellow\""),"selection color/highlight/underline commit through the actual toolbar")
            _ = try await js(0,"window.folio.command('comment');true");try await settle()
            _ = try await js(0,"(()=>{const t=document.querySelector('.comment-input');t.value='A small thought for the team.';t.dispatchEvent(new Event('input'));document.querySelector('button[aria-label=\"Add comment\"]').click();return true})()");try await settle();try await screenshot("writing-comments")
            try check(try await js(0,"document.querySelectorAll('.comment-thread').length") as! Int == 1,"selected text receives a persisted comment thread")
            try await click(0,".comment-actions button[aria-label=Reply]")
            _ = try await js(0,"(()=>{const t=document.querySelector('.comment-input');t.value='A reply with context.';t.dispatchEvent(new Event('input'));document.querySelector('[aria-label=\"Send reply\"]').click();return true})()");try await settle()
            try check(try await js(0,"document.querySelectorAll('.comment-message').length") as! Int == 2,"comment replies appear in their thread")
            try await click(0,"button[aria-label='Resolve comment']");try await click(0,"button[aria-label='Show resolved comments']");try await click(0,"button[aria-label='Reopen comment']")
            try await click(0,".writing-panel [aria-label=Close]")
            let saved=try await text(0);try await load(0,saved);try await load(1,saved)
            try check(try await js(0,"document.querySelectorAll('[data-omega-color=blue]').length") as! Int > 0,"formatted Markdown reopens as visual text")
            try check(try await js(0,"document.querySelector('.note-tools button[data-count]').dataset.count") as! String == "1","comment survives reload")
            try await join(0);try await join(1)
            let assistantBase=try await text(0),assistantNext=assistantBase.replacingOccurrences(of:"Good ideas",with:"Thoughtful ideas")
            let assistantApplied=try await js(0,"window.folio.replaceForAssistant(\(json(["id":"live","expected":assistantBase,"text":assistantNext,"activity":true])))") as! Bool
            try await settle()
            let assistantLeft=try await text(0),assistantRight=try await text(1)
            try check(assistantApplied && assistantLeft == assistantRight,"assistant updates converge in both live WebKit editors without leaving the session")
            sharing=false
            try await select(0,"next chapter");_ = try await js(0,"window.folio.command('color');true");try await click(0,"[aria-label='Text colors']");try await click(0,"[aria-label='Green text']")
            try await select(1,"new paragraph");_ = try await js(1,"window.folio.command('comment');true");try await settle()
            _ = try await js(1,"(()=>{const t=document.querySelector('.comment-input');t.value='From the second editor.';t.dispatchEvent(new Event('input'));document.querySelector('button[aria-label=\"Add comment\"]').click();return true})()");try await settle();try await click(1,".writing-panel [aria-label=Close]")
            let a=checkpoints[0]!,b=checkpoints[1]!;sharing=true;deliver(0,["type":"update","update":b["state"]!]);deliver(1,["type":"update","update":a["state"]!]);try await settle()
            let merged=try await text(0);try check(try await text(1)==merged && merged.contains("data-omega-color=\"green\""),"simultaneous color and comment changes converge in two real WebKit editors")
            try check(try await js(0,"document.querySelector('.note-tools button[data-count]').dataset.count") as! String == "2","both comment threads remain after CRDT merge")
            _ = try await js(0,"window.folio.command('undo');true");try await settle()
            let undone=try await text(1);try check(!undone.contains("data-omega-color=\"green\"") && undone.contains("omega-comment:"),"live undo removes local styling while preserving the other author's comment")
            // Exercise the hover handle through the same events used by the UI.
            _ = try await js(0,"window.folio.liveStop();true");try await load(0,note)
            _ = try await js(0,"document.querySelector('#editor .tiptap h2').dispatchEvent(new PointerEvent('pointermove',{bubbles:true,clientX:300,clientY:170}));true");try await click(0,".block-tools button:last-child");try await screenshot("writing-block-actions");try await click(0,".block-menu [aria-label=Duplicate]")
            try check(try await text(0).components(separatedBy:"## The next chapter").count == 3,"block menu duplicates a heading")
            _ = try await js(0,"document.querySelector('#editor .tiptap li').dispatchEvent(new PointerEvent('pointermove',{bubbles:true,clientX:300,clientY:200}));true");try await click(0,".block-tools button:first-child")
            try check(try await js(0,"!document.querySelector('#slash').hidden") as! Bool,"plus opens slash menu within a list")
            try await load(0,note);try await select(0,"A new paragraph.")
            _ = try await js(0,"document.execCommand('insertText',false,'@');true");try await settle()
            try check(try await js(0,"!document.querySelector('#page-picker').hidden") as! Bool,"typing @ opens the mention picker")
            try await click(0,"#page-results button");try check(try await text(0).contains("[A linked note](./Linked.md)"),"mention inserts a real local Markdown link")
            let dragNote="# Moving blocks\n\n## A heading\n\n- First **item**\n  - Nested child\n- Second item\n- Third item\n\nA final paragraph.\n"
            try await load(0,dragNote)
            let beforeDrag=try await text(0)
            try await drag("#editor .tiptap > ul > li:first-child","#editor .tiptap > ul > li:last-child",cancel:true)
            try check(try await text(0)==beforeDrag,"Escape cancels movement without editing the document")
            try await drag("#editor .tiptap > ul > li:first-child","#editor .tiptap > ul > li:last-child")
            let dragged=try await text(0)
            try check(dragged.range(of:"Third item")!.lowerBound<dragged.range(of:"First **item**")!.lowerBound && dragged.contains("Nested child"),"pointer drag reorders a list item with its nested children and formatting")
            try await load(0,dragged)
            try check(try await text(0)==dragged,"dragged Markdown reopens intact")
            try await load(0,dragNote)
            try await drag("#editor .tiptap h2","#editor .tiptap > ul > li:last-child")
            let headingMoved=try await text(0)
            try check(headingMoved.range(of:"Third item")!.lowerBound<headingMoved.range(of:"## A heading")!.lowerBound,"heading drops after a whole list even when targeting its last item")
            let longDragNote="# Long note\n\n"+(0..<60).map { "Paragraph \($0)." }.joined(separator:"\n\n")
            try await load(0,longDragNote)
            _ = try await js(0,"""
            (()=>{const p=document.querySelector('#editor .tiptap > p'),r=p.getBoundingClientRect();p.dispatchEvent(new PointerEvent('pointermove',{bubbles:true,clientX:r.left+10,clientY:r.top+5}));const h=document.querySelector('.block-tools button:last-child'),b=h.getBoundingClientRect();h.dispatchEvent(new PointerEvent('pointerdown',{bubbles:true,cancelable:true,pointerId:20,button:0,clientX:b.left+8,clientY:b.top+8}));document.dispatchEvent(new PointerEvent('pointermove',{bubbles:true,cancelable:true,pointerId:20,buttons:1,clientX:300,clientY:innerHeight-3}));return true})()
            """);try await settle()
            try check(try await js(0,"document.querySelector('#scroller').scrollTop>0") as! Bool,"dragging near the bottom scrolls a long document")
            _ = try await js(0,"document.dispatchEvent(new PointerEvent('pointercancel',{bubbles:true,pointerId:20}));true");try await settle()
            try check(try await text(0)==longDragNote,"pointer cancellation leaves a long document unchanged")
            // Responsive controls and source-mode appearance use the same preference.
            views[0].setFrameSize(NSSize(width:360,height:640));try await load(0,note);try await click(0,".note-tools button:last-child");try await screenshot("writing-narrow")
            try check(try await js(0,"(()=>{const r=document.querySelector('.writing-panel').getBoundingClientRect();return r.left>=0&&r.right<=innerWidth})()") as! Bool,"appearance panel stays inside a narrow window")
            _ = try await js(0,"window.folio.configure({nativeHeader:true});window.folio.command('closeWriting');window.folio.command('comments');true");try await settle()
            try check(try await js(0,"document.querySelector('.note-tools').hidden") as! Bool,"native header replaces floating document controls")
            try check(try await js(0,"(()=>{const r=document.querySelector('.writing-panel').getBoundingClientRect();return r.top<=9&&Math.abs(r.right-innerWidth+8)<2})()") as! Bool,"native comments open against the top-right edge")
            try await screenshot("writing-native-comments")
            _ = try await js(0,"window.folio.command('closeWriting');window.folio.command('appearance');true");try await settle()
            try await screenshot("writing-native-appearance")
            print("PASS: real WebKit writing controls, independent typography, styled Markdown, durable comments, concurrent collaboration, undo and narrow layout")
        } catch {failed=true;print("FAIL:",error)}
        for view in views {view.evaluateJavaScript("window.folio.liveStop()",completionHandler:nil)}
        done=true
    }
}

@main struct Main {
    @MainActor static func main(){let test=WritingWebCheck();test.start(URL(fileURLWithPath:CommandLine.arguments[1]));if test.interactive { NSApp.run(); return };let deadline=Date().addingTimeInterval(test.interactive ? 1800 : 90);while !test.done && Date()<deadline {RunLoop.current.run(until:Date().addingTimeInterval(0.03))};exit(test.done && !test.failed ? 0 : 1)}
}
