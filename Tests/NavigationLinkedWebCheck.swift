import AppKit
import SwiftUI
import WebKit

@main struct NavigationLinkedWebCheck {
    @MainActor static func main() {
        setbuf(stdout, nil); _ = NSApplication.shared; OpusIcons.register(); NSApp.setActivationPolicy(.prohibited)
        Task { @MainActor in
            do { try await run(); print("PASS: navigation, board layout and live linked content"); exit(0) }
            catch { print("FAIL:", error); exit(1) }
        }; NSApp.run()
    }
    static func require(_ condition: Bool, _ message: String) throws { guard condition else { throw TaskPageError(message) }; print("PASS:", message) }
    @MainActor static func js(_ view: WKWebView, _ code: String) async throws -> Any { try await view.evaluateJavaScript(code) }
    @MainActor static func wait(_ condition: @MainActor () async throws -> Bool) async throws {
        for _ in 0..<400 { if (try? await condition()) == true { return }; try await Task.sleep(for: .milliseconds(40)) }
        throw TaskPageError("Timed out waiting for UI")
    }
    @MainActor static func snap(_ view: NSView, _ url: URL) throws {
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        try bitmap.representation(using: .png, properties: [:])?.write(to: url)
    }
    @MainActor static func run() async throws {
        let output = URL(fileURLWithPath: CommandLine.arguments[1]), root = output.appendingPathComponent("Studio")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let noteURL = root.appendingPathComponent("Overview.md"), taskURL = root.appendingPathComponent("Tasks.md"), sourceURL = root.appendingPathComponent("Plan.md")
        var task = "<!-- folio:tasks -->\n# A thoughtful launch\n\n## Goals\n- [ ] Ship the next chapter\n  <!-- folio:task {\"id\":\"goal\"} -->\n\n## To do\n- [ ] Shape an idea\n  <!-- folio:task {\"id\":\"idea\",\"goals\":[\"goal\"]} -->\n  - [ ] Gather inspiration\n    <!-- folio:task {\"id\":\"child\"} -->\n\n## In review\n- [ ] Check the details\n  <!-- folio:task {\"id\":\"review\"} -->\n"
        for name in ["Planning","Waiting","Ready","Done"] { task += "\n## " + name + "\n- [ ] Work in " + name + "\n" }
        try task.write(to: taskURL, atomically: true, encoding: .utf8)
        try "# Plan\n\n## Direction\n\nA quiet place to think.\n\n## Next\n\nThis section is not quoted.\n".write(to: sourceURL, atomically: true, encoding: .utf8)
        let note = "# Overview\n\n```omega-quote\nPlan.md#omega-section-Direction\n```\n\n| Work | Status | Progress |\n| --- | --- | --- |\n| [Shape an idea](Tasks.md#folio-task-idea) | [Status](Tasks.md#folio-task-idea) | [Progress](Tasks.md#folio-task-idea) |\n| [Goal](Tasks.md#folio-goal-goal) | [Status](Tasks.md#folio-goal-goal) | [Progress](Tasks.md#folio-goal-goal) |\n\n[All work](Tasks.md)\n"
        try note.write(to: noteURL, atomically: true, encoding: .utf8)
        let followup = "<!-- folio:tasks -->\n# Follow-up\n\n## To do\n\n## Done\n- [x] A linked task from another page\n  <!-- folio:task {\"id\":\"external\",\"goals\":[\"alias\"],\"omegaGoalSources\":{\"alias\":{\"path\":\"Tasks.md\",\"id\":\"goal\"}}} -->\n"
        try followup.write(to: root.appendingPathComponent("Follow-up.md"), atomically: true, encoding: .utf8)
        let notebook = Notebook(recovery: DraftRecovery(directory: output.appendingPathComponent("Recovery")))
        notebook.root=root;notebook.notebooks=[root];notebook.reloadTree();notebook.appearance="dark";notebook.zoom=1;notebook.sidebar=false;notebook.fullscreen=true
        let host=NSHostingView(rootView:FolioView(notebook:notebook).preferredColorScheme(.dark));host.safeAreaRegions=[]
        let window=NSWindow(contentRect:NSRect(x:0,y:0,width:1400,height:850),styleMask:[.titled],backing:.buffered,defer:false);window.contentView=host;window.orderFront(nil)
        notebook.select(noteURL)
        try await wait { guard let web=notebook.richEditor?.webView else{return false};return try await js(web,"document.querySelector('.linked-quote-preview')?.textContent.includes('A quiet place') && document.querySelectorAll('.live-reference').length>=6") as? Bool == true }
        let web=notebook.richEditor!.webView!
        // A slow native response must not accumulate a new full scan every two seconds.
        _ = try await js(web, "window.testOriginalReferences=window.omegaReferenceRequest;window.testReferenceCalls=0;window.testHeldReference=null;window.omegaReferenceRequest=(...args)=>{window.testReferenceCalls++;window.testHeldReference=args};true")
        try await Task.sleep(for: .seconds(5))
        try require(try await js(web,"window.testReferenceCalls===1") as? Bool == true,"slow linked updates allow only one request in flight")
        _ = try await js(web,"window.omegaReferenceRequest=window.testOriginalReferences;window.omegaReferenceRequest(...window.testHeldReference);true")
        // Native discovery must remain available even during document loading.
        notebook.loading = true
        var discovery: [String: Any]?
        AssistantService(notebook).handle(["name":"get_context"]) { discovery = $0 }
        try require(discovery?["isError"] as? Bool == false,"assistant discovery does not depend on editor synchronization")
        notebook.loading = false
        try require(try await js(web,"!document.querySelector('.linked-quote-preview').textContent.includes('This section is not quoted') && document.querySelector('.live-reference-status').textContent==='To do'") as? Bool == true,"quotes follow only their selected section; task statuses appear inside table cells")
        try require(try await js(web,"[...document.querySelectorAll('.live-reference')].some(n=>n.title.includes('Ship the next chapter')&&n.title.includes('1/2'))") as? Bool == true,"goal references include linked tasks from other source pages")
        try await Task.sleep(for: .milliseconds(250))
        try snap(host,output.appendingPathComponent("linked-content.png"))
        _ = try await js(web,"document.querySelector('[aria-label=\"Edit linked section source\"]').click();var source=document.querySelector('.linked-quote-input');source.value='Plan.md#omega-section-Next';source.dispatchEvent(new Event('input',{bubbles:true}));true")
        do { try await wait { try await js(web,"document.querySelector('.linked-quote-preview')?.textContent.includes('This section is not quoted')") as? Bool == true } }
        catch { print("QUOTE EDIT",try await js(web,"({text:window.folio.snapshot().text,preview:document.querySelector('.linked-quote-preview')?.textContent})"));throw error }
        print("PASS: changing a quote source switches to the chosen section")
        _ = try await js(web,"window.folio.command('undo');true")
        do { try await wait { try await js(web,"document.querySelector('.linked-quote-preview')?.textContent.includes('A quiet place') && window.folio.snapshot().text.includes('Plan.md#omega-section-Direction')") as? Bool == true } }
        catch { print("QUOTE UNDO",try await js(web,"({text:window.folio.snapshot().text,preview:document.querySelector('.linked-quote-preview')?.textContent})"));throw error }
        print("PASS: linked section source editing and native undo restore the exact reference")
        _ = try await js(web,"document.querySelector('[aria-label=\"Edit linked section source\"]').click();true")
        try "# Plan\n\n## Direction\n\nAn updated direction, from the source.\n\n## Next\n\nAnother section.\n".write(to:sourceURL,atomically:true,encoding:.utf8)
        task=task.replacingOccurrences(of:"\"id\":\"idea\",",with:"\"id\":\"idea\",\"status\":\"In review\",")
        // Main task statuses live in headings, so move its full family to review.
        task=task.replacingOccurrences(of:"## To do\n",with:"## To do\n\n## In review\n").replacingOccurrences(of:"\n## In review\n- [ ] Check",with:"\n- [ ] Check")
        try task.write(to:taskURL,atomically:true,encoding:.utf8)
        try await wait { try await js(web,"document.querySelector('.linked-quote-preview')?.textContent.includes('updated direction') && document.querySelector('.live-reference-status')?.textContent==='In review'") as? Bool == true }
        try require(try String(contentsOf:noteURL,encoding:.utf8)==note,"live quotes and status refresh never rewrite the destination note")
        try FileManager.default.removeItem(at:sourceURL)
        try await wait { try await js(web,"document.querySelector('.linked-quote-preview')?.classList.contains('unavailable')") as? Bool == true }
        print("PASS: missing sources show an explicit unavailable state")
        notebook.showChecklist(in:root)
        try await wait { notebook.folderTasksEditor?.ready == true && notebook.folderTasksEditor?.snapshot != nil }
        let board=notebook.folderTasksEditor!.webView!
        _ = try await js(board,"document.querySelector('[aria-label=\"Board view\"]').click();true")
        try await wait { notebook.taskHeaderInset > 0 }
        try require(try await js(board,"document.querySelector('.tasks-header').getBoundingClientRect().top===0 && document.querySelector('.tasks-heading').getBoundingClientRect().left>=270 && document.querySelector('.tasks-header').getBoundingClientRect().height<65") as? Bool == true,"fullscreen task title shares the native toolbar row")
        try require(try await js(board,"[...document.querySelectorAll('.board>.task-group')].every(n=>n.getBoundingClientRect().width>=300) && document.querySelector('.board').scrollWidth>document.querySelector('.board').clientWidth") as? Bool == true,"seven statuses retain readable columns and scroll horizontally")
        try require(try await js(board,"getComputedStyle(document.querySelector('.task-card:not(.subtask-card)')).backgroundColor!==getComputedStyle(document.querySelector('.subtask-card')).backgroundColor") as? Bool == true,"task and subtask cards have distinct subtle fills")
        _ = try await js(board,"document.querySelector('.board').scrollLeft=420;true")
        try await Task.sleep(for: .milliseconds(250))
        let boardImage = try await board.takeSnapshot(configuration: nil)
        if let data = boardImage.tiffRepresentation, let bitmap = NSBitmapImageRep(data: data) { try bitmap.representation(using: .png, properties: [:])?.write(to: output.appendingPathComponent("wide-board.png")) }
        _ = try await js(board,"document.querySelector('[aria-label=\"Open task: Shape an idea\"]').click();true")
        _ = try await js(board,"document.querySelector('.task-detail>.folder-source').click();true")
        try await wait { notebook.checklistFolder == nil && notebook.selected == taskURL && !notebook.navigating }
        try require(notebook.canGoBack,"opening a task's source records a back destination")
        notebook.travelNavigation(forward:false)
        try await wait { guard let v=notebook.folderTasksEditor?.webView else{return false};guard notebook.checklistFolder==root else { return false }; return (try await js(v,"document.querySelector('.task-detail-title')?.value==='Shape an idea'") as? Bool == true) }
        print("PASS: Back restores the folder's exact task detail")
        notebook.travelNavigation(forward:true)
        try await wait { notebook.checklistFolder==nil && notebook.selected==taskURL && !notebook.navigating }
        try await wait { try await js(web,"document.querySelector('.task-detail-title')?.value==='Shape an idea'") as? Bool == true }
        print("PASS: Forward restores the linked task detail")
        notebook.travelNavigation(forward:false)
        try await wait { notebook.checklistFolder==root && !notebook.navigating }
        notebook.select(noteURL)
        try await wait { notebook.selected==noteURL && notebook.checklistFolder==nil && !notebook.navigating }
        try require(!notebook.canGoForward,"new navigation clears the forward branch")
        try require(try String(contentsOf:noteURL,encoding:.utf8)==note,"navigation preserves the note byte for byte")
        window.orderOut(nil)
    }
}
