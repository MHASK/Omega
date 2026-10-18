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
    func run() async {
        do {
            view.pageZoom=1.4
            let fontsLoaded = try await view.callAsyncJavaScript("return (await document.fonts.load('900 12px \"Font Awesome 5 Free\"')).length > 0", arguments: [:], in: nil, contentWorld: .page)
            guard fontsLoaded as? Bool == true else {throw UndoHistory.Failure(message:"Bundled icon font failed to load")}
            print("PASS: bundled icons load from the app resource boundary")
            var fixture=TaskDocument(title:"A thoughtful launch")
            fixture.goals=[TaskCheckItem(title:"Give the next version a quiet, considered start")]
            fixture.tasks=[
                TaskPageItem(title:"A welcoming first impression",status:"To do",subtasks:[TaskCheckItem(title:"Write the opening sentence",details:TaskDetails(id:"child-a",description:"Keep it warm and clear.",status:"To do")),TaskCheckItem(title:"Review the empty states",details:TaskDetails(id:"child-b",status:"In progress"))],details:TaskDetails(id:"parent-a",description:"Make the first few minutes feel effortless.\n\nReview the welcome page, the first note, and the little moments in between.",due:"2026-10-20",labels:["Writing","ads","claude"])),
                TaskPageItem(title:"Polish the small details",status:"In progress",subtasks:[TaskCheckItem(title:"Check keyboard navigation",details:TaskDetails(id:"child-c",status:"In progress"))],details:TaskDetails(id:"parent-b",labels:["Interface"])),
                TaskPageItem(title:"Choose the essentials",status:"Done",details:TaskDetails(id:"parent-c"))]
            let text=fixture.markdown
            try await load(text,"tasks")
            _=try await js("window.folio.configure({theme:'dark',zoom:1.4,accent:'#c7b6e6'});true")
            try await assertJS("!document.querySelector('#task-page').hidden&&document.querySelectorAll('.task-list-row').length===3", "compact lists begin with one row per main task")
            guard current==text else {throw UndoHistory.Failure(message:"Opening tasks changed the file")}
            try await assertJS("document.querySelector('.tasks-page-progress').dataset.progress===String(1/6)", "the title ring measures the complete project before subtasks are expanded")
            try await assertJS("(()=>{const labels=[...document.querySelectorAll('.task-row-labels .task-label[data-label-tone]')];return labels.length>1&&labels.every(l=>getComputedStyle(l).textTransform==='uppercase')&&new Set(labels.map(l=>getComputedStyle(l).color)).size>1})()", "list tags render uppercase with distinct pastel colors")
            try await assertJS("(()=>{let h=document.querySelector('.tasks-header').getBoundingClientRect(),g=document.querySelector('.task-groups').getBoundingClientRect(),t=document.querySelector('.tasks-title').getBoundingClientRect(),c=document.querySelector('.tasks-controls').getBoundingClientRect();return Math.abs(h.left)<2&&Math.abs(h.right-innerWidth)<2&&h.top===0&&Math.abs(g.left-h.left)<2&&Math.abs(g.right-h.right)<2&&Math.abs(t.top-c.top)<10})()", "the task header and compact list reach both edges, with header controls on one line")
            _=try await js("window.folio.configure({theme:'dark',zoom:1.4,taskHeaderInset:280});window.folio.command('source');window.folio.command('source');true");try await settle()
            try await assertJS("document.querySelector('.tasks-heading').getBoundingClientRect().left>=280", "switching document formats preserves space for native navigation controls")
            _=try await js("window.folio.configure({theme:'dark',zoom:1.4,taskHeaderInset:0});true")
            try await assertJS("(()=>{const rows=[...document.querySelectorAll('.task-list-row')];return rows.every(r=>r.getBoundingClientRect().height<43)&&rows.every(r=>{const t=r.querySelector('.task-row-title').getBoundingClientRect(),s=r.querySelector('.task-row-state').getBoundingClientRect();return Math.abs((t.top+t.height/2)-(s.top+s.height/2))<3})})()", "list titles and properties share a compact single-line baseline")
            _=try await js("document.querySelector('[data-task=parent-a] .task-row-disclosure').click();true");try await settle()
            try await assertJS("document.querySelectorAll('.task-list-row').length===5&&document.querySelector('[data-task=child-b] select').value==='1'", "expanding a parent reveals children with their independent statuses")
            try await assertJS("(()=>{const rows=[...document.querySelectorAll('.task-list-row')];return new Set(rows.map(r=>r.dataset.task)).size===rows.length})()", "each expanded task appears once in the list hierarchy")
            guard current==text else {throw UndoHistory.Failure(message:"Expanding the list changed the document")}
            _=try await js("(()=>{const t=document.querySelector('[data-task=parent-a] .task-row-title');t.focus();t.dispatchEvent(new KeyboardEvent('keydown',{key:'ArrowDown',bubbles:true}));return true})()");try await settle()
            try await assertJS("document.activeElement.closest('[data-task]')?.dataset.task==='child-a'", "arrow keys navigate visible task rows")
            _=try await js("document.querySelector('.task-group-toggle').click();true");try await settle()
            try await assertJS("!document.querySelector('[data-task=parent-a]')", "status groups collapse without modifying tasks")
            _=try await js("document.querySelector('.task-group-toggle').click();true");try await settle()
            guard current==text else {throw UndoHistory.Failure(message:"Changing list visibility modified the document")}
            try await snapshot("-list")
            _=try await js("document.documentElement.dataset.theme='light';true");try await settle();try await snapshot("-list-light")
            _=try await js("document.documentElement.dataset.theme='dark';true")
            _=try await js("document.querySelector('[aria-label=\"Board view\"]').click();true");try await settle()
            try await assertJS("[...document.querySelectorAll('.task-card-labels .task-label[data-label-tone]')].every(l=>getComputedStyle(l).textTransform==='uppercase')", "board tags share the uppercase pastel style")
            try await snapshot("-board")
            _=try await js("document.documentElement.dataset.theme='light';true");try await settle();try await snapshot("-board-light")
            _=try await js("document.documentElement.dataset.theme='dark';true")
            try await assertJS("!!document.querySelector('.task-parent-context')&&document.querySelectorAll('.subtask-card').length===3", "subtasks keep their parent context across status columns")
            _=try await js("document.querySelector('[aria-label=\"Add\"]').click();document.querySelector('[aria-label=\"Add task\"]').click();true");try await settle()
            guard current==text else {throw UndoHistory.Failure(message:"Empty composer changed the file")}
            try await assertJS("!!document.querySelector('[role=dialog]')", "new tasks open in a focused composer")
            try await assertJS("document.querySelector('[aria-label=\"Due date\"]').value===''&&!document.querySelector('.task-date-property').classList.contains('has-date')", "empty dates show a quiet Due date prompt")
            _=try await js("(()=>{let f=document.querySelector('.task-composer-title');f.value='A new beginning';f.dispatchEvent(new Event('input'));let d=document.querySelector('.task-composer .task-description .tiptap');d.focus();document.execCommand('insertText',false,'Keep the experience simple, considered, and entirely local.');return true})()");try await settle()
            let draft=current
            let parsedDraft=try TaskDocument(markdown:draft);precondition(parsedDraft.tasks.contains(where:{$0.title=="A new beginning" && $0.details.draft==true}))
            try await snapshot("-composer")
            _=try await js("document.querySelector('[aria-label=\"Expand task composer\"]').click();true");try await settle()
            try await assertJS("!!document.querySelector('.task-overlay.is-full')", "composer expands into the document area")
            _=try await js("document.querySelector('[aria-label=\"Dock task composer\"]').click();true");try await settle()
            try await assertJS("!!document.querySelector('.task-dock')", "composer docks without losing its draft")
            guard current==draft else {throw UndoHistory.Failure(message:"Docking altered the draft")}
            _=try await js("document.querySelector('[aria-label=\"Restore task composer\"]').click();document.querySelector('[aria-label=\"Create task\"]').click();true");try await settle()
            let created=try TaskDocument(markdown:current);precondition(created.tasks.contains(where:{$0.title=="A new beginning" && $0.details.draft != true}))
            _=try await js("document.querySelector('[data-task=\"parent-a\"] .task-card-title').click();true");try await settle()
            try await assertJS("!!document.querySelector('.task-detail')&&document.querySelectorAll('.task-detail-child').length===2", "a parent opens as a detail page with its subtasks")
            try await snapshot("-detail")
            let beforeMove=current
            _=try await js("(()=>{let s=document.querySelector('.task-detail-header .task-status-select');s.value='1';s.dispatchEvent(new Event('change'));return true})()");try await settle()
            let moved=try TaskDocument(markdown:current);precondition(moved.tasks.first(where:{$0.details.id=="parent-a"})?.status=="In progress")
            _=try await js("window.folio.command('undo');true");try await settle();precondition(current==beforeMove)
            _=try await js("document.querySelector('[aria-label=\"Open subtask: Write the opening sentence\"]').click();true");try await settle()
            try await assertJS("!!document.querySelector('[aria-label=\"Open parent task\"]')&&!!document.querySelector('[aria-label=\"Subtask status\"]')", "subtasks have their own details and navigation to the parent")
            let beforeDelete=current
            _=try await js("document.querySelector('[aria-label=\"More task actions\"]').click();document.querySelector('[aria-label=\"Remove task\"]').click();document.querySelector('[aria-label=\"Confirm remove task\"]').click();true");try await settle()
            _=try await js("window.folio.command('undo');true");try await settle();precondition(current==beforeDelete)
            print("PASS: detail edits and subtask deletion use persistent undo")
            try await load(text,"layout")
            view.frame.size=NSSize(width:360,height:680);view.pageZoom=2.5;try await settle()
            _=try await js("document.querySelector('[aria-label=\"Board view\"]').click();true");try await settle()
            try await assertJS("(()=>{let p=document.querySelector('#task-page'),b=document.querySelector('.board');return p.scrollWidth<=p.clientWidth+1&&b.scrollWidth>b.clientWidth})()", "narrow boards scroll inside the page")
            _=try await js("document.querySelector('[aria-label=\"List view\"]').click();true");try await settle()
            try await assertJS("(()=>{let p=document.querySelector('#task-page');return p.scrollWidth<=p.clientWidth+1})()", "narrow lists retain compact rows without clipping")
            _=try await js("document.querySelector('[aria-label=\"Add\"]').click();document.querySelector('[aria-label=\"Add task\"]').click();true");try await settle()
            try await assertJS("(()=>{let o=document.querySelector('.task-overlay');return o.scrollWidth<=o.clientWidth+1})()", "composer fields fit very small windows at high zoom")
            _=try await js("document.querySelector('[aria-label=\"Save draft and close\"]').click();true")
            let assistantText=current.replacingOccurrences(of:"## Goals\n",with:"## Goals\n\n- [ ] Shared goal\n")
            let request=try JSONSerialization.data(withJSONObject:["id":id,"expected":current,"text":assistantText])
            try await assertJS("window.folio.replaceForAssistant(\(String(decoding:request,as:UTF8.self)))", "MCP edits still update the visible task page atomically")
            try await settle()
            try await assertJS("!window.folio.replaceForAssistant(\(String(decoding:request,as:UTF8.self)))", "stale MCP edits are rejected")
            _=try await js("window.folio.command('undo');true");try await settle();precondition(current==text)
            view.frame.size=NSSize(width:1100,height:900);view.pageZoom=1.4
            let blank=TaskDocument(title:"A fresh start").markdown
            try await load(blank,"empty-tasks")
            try await assertJS("document.querySelector('.task-page-empty')?.textContent.includes('No tasks yet')===true", "empty task pages provide a clear starting point")
            try await snapshot("-empty")
            var emptyDetail=TaskDocument(title:"A fresh start");emptyDetail.tasks=[TaskPageItem(title:"A small next step",status:"To do",details:TaskDetails(id:"empty-details"))]
            try await load(emptyDetail.markdown,"empty-detail")
            _=try await js("document.querySelector('[data-task=\"empty-details\"] .task-card-title').click();true");try await settle()
            try await snapshot("-empty-detail")
            _=try await js("document.querySelector('[aria-label=\"Labels\"]').click();true");try await settle();try await snapshot("-labels")
            try await assertJS("(()=>{let p=document.querySelector('.task-label-picker'),b=document.querySelector('[aria-label=\"Labels\"]');return !p.hidden&&b.offsetWidth<90&&!document.querySelector('.task-detail-footer')})()", "labels stay compact and removal is kept out of the document")
            _=try await js("(()=>{let f=document.querySelector('.task-label-search');f.value='Focus';f.dispatchEvent(new Event('input'));document.querySelector('[aria-label=\"Create label: Focus\"]').click();f.dispatchEvent(new KeyboardEvent('keydown',{key:'Escape',bubbles:true}));return true})()");try await settle()
            let labelled=try TaskDocument(markdown:current);precondition(labelled.tasks.first?.details.labels == ["Focus"])
            let beforeCancel=current
            _=try await js("document.querySelector('[aria-label=\"More task actions\"]').click();document.querySelector('[aria-label=\"Remove task\"]').click();true");try await settle();try await snapshot("-confirm")
            _=try await js("document.querySelector('[aria-label=\"Keep task\"]').click();true");try await settle()
            precondition(current == beforeCancel)
            try await load(text,"move-links")
            _=try await js("document.querySelector('[data-task=parent-a] .task-row-disclosure').click();true");try await settle()
            _=try await js("document.querySelector('[data-task=child-a] .task-card-title').click();document.querySelector('[aria-label=\"More task actions\"]').click();document.querySelector('[aria-label=\"Make main task\"]').click();true");try await settle()
            var promoted=try TaskDocument(markdown:current)
            guard promoted.tasks.contains(where:{$0.details.id=="child-a"&&$0.details.description=="Keep it warm and clear."}) else {throw UndoHistory.Failure(message:"Promotion dropped details")}
            _=try await js("window.folio.command('undo');true");try await settle()
            promoted=try TaskDocument(markdown:current)
            guard promoted.tasks[0].subtasks[0].details.id=="child-a" else {throw UndoHistory.Failure(message:"Promotion undo did not restore hierarchy")}
            _=try await js("window.folio.revealItem({id:'move-links',item:'parent-a',kind:'task'});document.querySelector('[aria-label=\"More task actions\"]').click();document.querySelector('[aria-label=\"Move under task\"]').click();true");try await settle();try await snapshot("-move-picker")
            _=try await js("document.querySelector('[aria-label=\"Move under Polish the small details\"]').click();true");try await settle()
            let reparented=try TaskDocument(markdown:current)
            guard reparented.tasks.first(where:{$0.details.id=="parent-b"})?.subtasks.first(where:{$0.details.id=="parent-a"})?.subtasks.count==2 else {throw UndoHistory.Failure(message:"Move lost descendants")}
            try await assertJS("window.folio.revealItem({id:'move-links',item:'child-a',kind:'task'})", "a stable item link opens the nested subtask after its parent moves")
            _=try await js("(()=>{const d=document.querySelector('.task-description .tiptap');d.focus();document.execCommand('selectAll');document.execCommand('insertText',false,'/goal');return true})()");try await settle()
            try await assertJS("!document.querySelector('.task-description-slash').hidden&&document.querySelector('.task-description-slash').textContent.includes('Link to goal')", "task descriptions filter slash links as you type")
            print("PASS: label creation saves to Markdown and canceling removal preserves the task")
            try await load("# <Weekday>, <D Month YYYY>\n\n## Summary\n\nTemplate <project>.\n","template")
            try await assertJS("document.querySelector('#source').hidden&&document.querySelector('h1').textContent==='<Weekday>, <D Month YYYY>'", "ordinary note rendering remains intact")
            try await load(text,"pastel-labels")
            _=try await js("document.querySelector('[data-task=parent-a] .task-row-title').click();document.querySelector('[aria-label=\"Labels\"]').click();true");try await settle()
            try await assertJS("(()=>{let t=document.querySelector('[aria-label=\"Labels\"]'),chips=[...document.querySelectorAll('.task-label-choice .task-label')];return !!t.dataset.labelTone&&getComputedStyle(t.querySelector('span:last-child')).textTransform==='uppercase'&&chips.length>=3&&chips.every(c=>getComputedStyle(c).textTransform==='uppercase')&&new Set(chips.map(c=>getComputedStyle(c).color)).size>=3})()", "detail properties and picker choices share uppercase pastel labels")
            try await snapshot("-pastel-labels")
            _=try await js("document.documentElement.dataset.theme='light';true");try await settle();try await snapshot("-pastel-labels-light")
            guard current==text else {throw UndoHistory.Failure(message:"Rendering tags changed stored label names")}
            try await load(text,"completion-rings")
            _=try await js("document.querySelector('[data-task=parent-a] .task-row-disclosure').click();document.querySelector('[data-task=child-a] .task-check').click();true");try await settle()
            try await assertJS("document.querySelector('[data-task=parent-a] .task-row-progress .completion-ring').dataset.progress==='0.5'", "parent ring follows subtask completion")
            try await assertJS("document.querySelector('.tasks-page-progress').dataset.progress===String(2/6)", "the title ring updates when a subtask is completed")
            try await assertJS("[...document.querySelectorAll('.completion-ring')].every(r=>{let b=r.getBoundingClientRect();return b.width>=12&&b.width===b.height&&getComputedStyle(r).color==='rgb(199, 182, 230)'})", "rings stay circular and use the notebook accent")
            try await snapshot("-rings-list")
            _=try await js("document.querySelector('[aria-label=\"Board view\"]').click();true");try await settle()
            try await assertJS("document.querySelector('[data-task=parent-a] .task-progress .completion-ring').dataset.progress==='0.5'", "board and list share the same completion value")
            try await snapshot("-rings-board")
            _=try await js("window.folio.command('undo');true");try await settle()
            try await assertJS("document.querySelector('[data-task=parent-a] .completion-ring').dataset.progress==='0'", "undo immediately refreshes the completion ring")
            guard current==text else {throw UndoHistory.Failure(message:"Progress undo did not restore the note")}
            _=try await js("document.querySelector('[aria-label=\"List view\"]').click();true");try await settle()
            try await load(text,"linked-goals")
            _=try await js("document.querySelector('[data-task=parent-a] .task-row-title').click();document.querySelector('[aria-label=\"Choose goals\"]').click();document.querySelector('[aria-label^=\"Link goal: \"]').click();true");try await settle()
            let linkedDocument = try TaskDocument(markdown: current)
            precondition(linkedDocument.tasks[0].details.goals == [linkedDocument.goals[0].details.id!])
            try await assertJS("!!document.querySelector('[aria-label=\"Choose goals\"]')&&!document.querySelector('.goal-picker').hidden", "task details link a goal and keep the picker open")
            _=try await js("document.querySelector('[aria-label=\"Back to tasks\"]').click();document.querySelector('[aria-label=\"Manage goals\"]').click();document.querySelector('.goal-overview-row').click();true");try await settle()
            try await assertJS("document.querySelectorAll('.goal-linked-row').length===1&&document.querySelector('.goal-progress').textContent==='0/1'", "goal detail shows linked work and automatic progress")
            try await snapshot("-goal")
            _=try await js("document.querySelector('[aria-label=\"Complete linked task\"]').click();true");try await settle()
            try await assertJS("document.querySelector('.goal-progress').textContent==='1/1'&&document.querySelector('.goal-progress .completion-ring').dataset.progress==='1'", "completing a linked task updates goal progress")
            _=try await js("window.folio.command('undo');true");try await settle()
            let undoneGoals = try TaskDocument(markdown: current)
            precondition(undoneGoals.goalProgress(undoneGoals.goals[0]).completed == 0)
            _=try await js("document.querySelector('[aria-label=\"Back to tasks\"]').click();true");try await settle()
            try await assertJS("!document.querySelector('.task-goals')&&!!document.querySelector('.task-goal-badge')", "task list shows goal links without a separate goals section")
            view.frame.size=NSSize(width:360,height:660);view.pageZoom=2.5
            _=try await js("document.querySelector('[aria-label=\"Manage goals\"]').click();document.querySelector('.goal-overview-row').click();true");try await settle()
            try await assertJS("document.documentElement.scrollWidth<=innerWidth+2", "goal details fit a narrow window at high zoom")
            try await load(text,"project-ring-small")
            _=try await js("document.querySelector('[aria-label=\"List view\"]').click();true");try await settle()
            try await assertJS("(()=>{let r=document.querySelector('.tasks-page-progress').getBoundingClientRect(),t=document.querySelector('.tasks-title').getBoundingClientRect(),h=document.querySelector('.tasks-heading').getBoundingClientRect();return r.width===r.height&&r.left>=0&&r.right<t.left&&t.right<=innerWidth&&h.right<=innerWidth})()", "title and project ring fit a small window at high zoom")
            let outsideTask = "<!-- folio:tasks -->\n# Outside edit\n\n## To do\n- [ ] Parent\n  <!-- folio:task {\"id\":\"outside-parent\",\"status\":\"Done\",\"description\":\"Keep these details\",\"labels\":[\"Writing\"]} -->\n  - [ ] Child\n    <!-- folio:task {\"id\":\"outside-child\",\"status\":\"In progress\"} -->\n\n## In progress\n\n## Done\n"
            view.frame.size=NSSize(width:1100,height:900);view.pageZoom=1
            try await load(outsideTask,"outside-task")
            try await assertJS("document.getElementById('source').hidden&&!document.getElementById('task-page').hidden&&!!document.querySelector('.tasks-title')", "outside main-task status opens in task view without rewriting the file")
            precondition(current == outsideTask)
            let importedTask = outsideTask.replacingOccurrences(of: "## To do", with: "## Goals\n- [ ] Keep the goal\n  <!-- folio:task {\"id\":\"goal\",\"status\":\"Planning\",\"description\":\"Keep the description\",\"labels\":[\"goal\"]} -->\n\n## To do")
                .replacingOccurrences(of: "\"status\":\"In progress\"", with: "\"status\":\"Merged\"")
            try await load(importedTask, "imported-statuses")
            try await assertJS("document.getElementById('source').hidden&&!document.getElementById('task-page').hidden", "goal metadata and statuses without headings remain in the task interface")
            precondition(current == importedTask)
            _ = try await js("document.querySelector('[aria-label=\"List view\"]').click();document.querySelector('[aria-label=\"Open task: Parent\"]').click();true")
            try await settle()
            try await assertJS("!!document.querySelector('.task-detail-title')&&document.body.textContent.includes('Keep these details')", "imported task details are readable")
            try await snapshot("-imported-statuses")
            let invalidTask = outsideTask + "Unsupported extra content\n"
            try await load(invalidTask,"task-fallback")
            try await assertJS("!document.getElementById('source').hidden", "unrecognized task content remains intact in source fallback")
            let repairData = try JSONSerialization.data(withJSONObject:["id":id,"base":invalidTask,"text":outsideTask])
            _ = try await js("window.folio.applyExternal(\(String(decoding:repairData,as:UTF8.self)))")
            try await settle()
            try await assertJS("document.getElementById('source').hidden&&!document.getElementById('task-page').hidden", "repairing outside task edits automatically restores the task view")
            _ = try await js("window.folio.command('source');true")
            try await assertJS("!document.getElementById('source').hidden", "manual Markdown view can still be selected")
            let anotherEdit = outsideTask.replacingOccurrences(of:"# Outside edit",with:"# Another outside edit")
            let editData = try JSONSerialization.data(withJSONObject:["id":id,"base":outsideTask,"text":anotherEdit])
            _ = try await js("window.folio.applyExternal(\(String(decoding:editData,as:UTF8.self)))")
            try await settle()
            try await assertJS("!document.getElementById('source').hidden&&document.getElementById('source').value.includes('Another outside edit')", "outside edits preserve an intentionally selected Markdown view")
            try await load(outsideTask,"protected-preview")
            let brokenData = try JSONSerialization.data(withJSONObject:["id":id,"base":outsideTask,"text":invalidTask])
            _ = try await js("window.folio.applyExternal(\(String(decoding:brokenData,as:UTF8.self)))")
            try await settle()
            try await assertJS("!document.getElementById('task-page').hidden&&document.getElementById('source').hidden&&!document.getElementById('import-health').hidden&&document.getElementById('import-health').textContent.includes('read only')", "invalid outside task edits keep a clearly labeled last-valid preview")
            try await assertJS("document.querySelector('.tasks-title').disabled&&[...document.querySelectorAll('#task-page [data-mutates]')].every(n=>n.disabled)", "every task mutation is disabled in the recovery preview")
            _ = try await js("window.folio.configure({theme:'dark',reading:false});document.querySelector('[aria-label=\"Open task: Parent\"]').click();true")
            try await assertJS("document.querySelector('.task-detail-title').disabled", "opening task details and changing preferences cannot unlock stale content")
            let preserved = try await js("window.folio.snapshot().text") as! String
            precondition(preserved == invalidTask && current == invalidTask)
            try await snapshot("-protected-preview")
            _ = try await js("document.querySelector('#import-health button').click();true")
            try await assertJS("!document.getElementById('source').hidden&&document.getElementById('source').value.endsWith('Unsupported extra content\\n')", "View Markdown opens the latest outside file, never the old preview")
            _ = try await js("document.querySelector('#import-health button').click();true")
            let fixedData = try JSONSerialization.data(withJSONObject:["id":id,"base":invalidTask,"text":outsideTask])
            _ = try await js("window.folio.applyExternal(\(String(decoding:fixedData,as:UTF8.self)))")
            try await settle()
            try await assertJS("!document.getElementById('task-page').hidden&&document.getElementById('import-health').hidden&&!document.querySelector('.task-detail-title').disabled", "a valid outside repair automatically restores editable tasks and clears diagnostics")
            try await load(invalidTask,"unrelated-broken-file")
            try await assertJS("document.getElementById('task-page').hidden&&!document.getElementById('source').hidden&&!document.getElementById('import-health').textContent.includes('last valid')", "another file never inherits a stale task preview")
            let brokenTable = "# Table\n\n| Name | State |\n| --- | --- |\n| A | Open |\n\nA paragraph.\n\n| B | Done |\n"
            try await load(brokenTable,"table-warning")
            try await assertJS("document.getElementById('source').hidden&&document.querySelectorAll('.tiptap table').length===1&&document.getElementById('import-health').textContent.includes('table row')", "an orphan table row gets a visible explanation without hiding the readable note")
            let tableOriginal = try await js("window.folio.snapshot().text") as! String
            precondition(tableOriginal == brokenTable)
            try await load("---\ntitle: Outside metadata\n---\n# Note\n", "unsupported-dialect")
            try await assertJS("!document.getElementById('source').hidden&&document.getElementById('import-health').textContent.includes('front matter')", "unsupported note dialects explain why original Markdown is preserved")
            let workPlan = """
            <!-- folio:tasks -->
            # Team launch
            ## To do
            - [ ] Build the foundation
              <!-- folio:task {"id":"foundation","description":"Agree on the contract, implement it, then run the regression checks."} -->
            - [ ] Ship the release
              <!-- folio:task {"id":"release","omegaDependencies":[{"id":"foundation"}],"omegaHandoff":"Waiting for foundation review. Keep the migration reversible."} -->
            ## In progress
            - [ ] Polish the sign-in flow
              <!-- folio:task {"id":"signin","omegaAssignee":"Claude / sign-in","omegaBranch":"feature/sign-in","omegaSession":"sign-in-review","omegaHandoff":"Implemented the form. Keyboard and offline checks pass. Review the retry message."} -->
            ## Done
            """
            view.frame.size=NSSize(width:1100,height:900);view.pageZoom=1
            try await load(workPlan,"work-coordination")
            _ = try await js("document.querySelector('[aria-label=\"Ready view\"]').click();true")
            try await assertJS("document.querySelectorAll('.task-list-row').length===1&&!!document.querySelector('[data-task=foundation]')", "Ready shows only unassigned work with satisfied dependencies")
            try await snapshot("-ready")
            _ = try await js("document.querySelector('[aria-label=\"List view\"]').click();document.querySelector('[aria-label=\"Open task: Ship the release\"]').click();document.querySelector('.task-work-panel').open=true;document.querySelector('.task-work-panel').scrollIntoView({block:'center'});true")
            try await settle()
            try await assertJS("document.querySelector('.task-dependency-row').textContent.includes('Build the foundation')&&document.querySelector('[aria-label=Handoff]').value.includes('Waiting for foundation')", "Task details display linked prerequisites and the saved handoff")
            try await snapshot("-coordination-dark")
            _ = try await js("window.folio.configure({theme:'light'});true")
            try await snapshot("-coordination-light")
            view.frame.size=NSSize(width:480,height:800)
            try await settle()
            try await assertJS("document.documentElement.scrollWidth<=innerWidth+2&&[...document.querySelectorAll('.task-work-body input,.task-work-body textarea,.task-work-body select')].every(n=>n.getBoundingClientRect().right<=innerWidth)", "Work and handoff fields fit a narrow window")
            try await snapshot("-coordination-narrow")
            print("All task detail, composer, persistence and responsive checks passed.")
        } catch {print("FAIL",error);failed=true}
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
