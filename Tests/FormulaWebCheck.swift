import AppKit
import SwiftUI
import WebKit

@main struct FormulaWebCheck {
    @MainActor static func main(){setbuf(stdout,nil);_=NSApplication.shared;OpusIcons.register();NSApp.setActivationPolicy(.prohibited)
        Task { @MainActor in do {try await run();print("PASS: live formula editor integration");exit(0)}catch{print("FAIL:",error);exit(1)} };NSApp.run()
    }
    static func require(_ value:Bool,_ label:String)throws{guard value else{throw TaskPageError(label)};print("PASS:",label)}
    @MainActor static func js(_ web:WKWebView,_ code:String)async throws->Any{try await web.evaluateJavaScript(code)}
    @MainActor static func wait(_ f:@MainActor ()async throws->Bool)async throws{for _ in 0..<300{if (try? await f())==true{return};try await Task.sleep(for:.milliseconds(40))};throw TaskPageError("Timed out waiting for formulas")}
    @MainActor static func run()async throws{
        let out=URL(fileURLWithPath:CommandLine.arguments[1]), root=out.appendingPathComponent("Notebook"), sub=root.appendingPathComponent("Plans")
        try FileManager.default.createDirectory(at:sub,withIntermediateDirectories:true)
        let rates=root.appendingPathComponent("Rates.md"), note=sub.appendingPathComponent("Price proposal.md")
        let rate="# Rates\n\n## Unit prices\n\n| Item | Price |\n| --- | ---: |\n| API | 0.30 |\n"
        let text="# Price proposal\n\nLive values from the rates note.\n\n## Estimate\n\n| Item | Quantity | Unit price | Total |\n| --- | ---: | ---: | ---: |\n| API | 10 | `=CELL(\"../Rates.md\",\"Unit prices\",\"API\",\"Price\")` | `=ROUND(B2*C2,2)` |\n| Storage | 2 | 12.50 | `=B3*C3` |\n| Total with tax | | | `=ROUND(SUM(D2:D3)*1.18,2)` |\n\nValues update automatically; formulas remain in the source.\n"
        try rate.write(to:rates,atomically:true,encoding:.utf8);try text.write(to:note,atomically:true,encoding:.utf8)
        let book=Notebook(recovery:DraftRecovery(directory:out.appendingPathComponent("Recovery")));book.root=root;book.notebooks=[root];book.reloadTree();book.appearance="dark";book.zoom=1
        let host=NSHostingView(rootView:FolioView(notebook:book).preferredColorScheme(.dark));host.safeAreaRegions=[]
        let window=NSWindow(contentRect:NSRect(x:0,y:0,width:1200,height:760),styleMask:[.titled],backing:.buffered,defer:false);window.contentView=host;window.orderFront(nil);book.select(note)
        try await wait{guard let web=book.richEditor?.webView else{return false};return try await js(web,"document.querySelectorAll('.formula-result').length===4 && document.querySelector('table').rows[3].cells[3].querySelector('.formula-result')?.textContent==='33.04'") as? Bool == true}
        let web=book.richEditor!.webView!
        try require(try String(contentsOf:note,encoding:.utf8)==text,"rendering cross-folder formulas does not save computed values")
        let image=try await web.takeSnapshot(configuration:nil)
        if let data=image.tiffRepresentation,let bitmap=NSBitmapImageRep(data:data){try bitmap.representation(using:.png,properties:[:])?.write(to:out.appendingPathComponent("table-formulas-dark.png"))}
        try rate.replacingOccurrences(of:"0.30",with:"0.50").write(to:rates,atomically:true,encoding:.utf8)
        try await wait{try await js(web,"document.querySelector('table').rows[3].cells[3].querySelector('.formula-result')?.textContent==='35.4'") as? Bool == true}
        print("PASS: background source edits refresh chained totals in the open editor")
        try FileManager.default.removeItem(at:rates)
        try await wait{try await js(web,"document.querySelector('table').rows[3].cells[3].querySelector('.formula-result')?.textContent==='#REF!'") as? Bool == true}
        print("PASS: deleted sources invalidate downstream totals instead of displaying stale prices")
        try rate.write(to:rates,atomically:true,encoding:.utf8)
        try await wait{try await js(web,"document.querySelector('table').rows[3].cells[3].querySelector('.formula-result')?.textContent==='33.04'") as? Bool == true}
        _=try await js(web,"window.formulaErrors=[];window.onerror=m=>window.formulaErrors.push(m);document.querySelector('table').rows[1].cells[3].querySelector('.formula-result').dispatchEvent(new MouseEvent('mousedown',{bubbles:true}));true")
        try await wait{try await js(web,"!document.querySelector('#table-tools').hidden") as? Bool == true}
        _=try await js(web,"document.querySelector('#table-formula').click();true")
        try require(try await js(web,"!document.querySelector('#entry').hidden && document.querySelector('#entry-input').value==='=ROUND(B2*C2,2)'") as? Bool == true,"formula result opens its source and compact formula control")
        _=try await js(web,"window.savedFormulaReceive=window.omegaFormulas.receive;window.heldFormulaReplies=[];window.omegaFormulas.receive=(...args)=>window.heldFormulaReplies.push(args);true")
        try await wait{try await js(web,"window.heldFormulaReplies.length>0") as? Bool == true}
        try require(try await js(web,"""
            window.savedFormulaRequest=window.omegaFormulaRequest;window.formulaSent=0;
            window.omegaFormulaRequest=(...args)=>{window.formulaSent++;window.savedFormulaRequest(...args)};
            document.querySelector('#entry-input').value='=ROUND(B2*C2*2,2)';
            document.querySelector('#entry').dispatchEvent(new Event('submit',{bubbles:true,cancelable:true}));
            window.savedFormulaReceive(...window.heldFormulaReplies.shift());
            window.omegaFormulas.receive=window.savedFormulaReceive;
            window.formulaSent===0 && document.querySelector('table').rows[3].cells[3].querySelector('.formula-result')?.textContent!=='33.04'
            """) as? Bool == true,"delayed replies cannot restore an old total or send an old snapshot after a new edit")
        try await wait{try await js(web,"window.folio.snapshot().text.includes('`=ROUND(B2*C2*2,2)`')") as? Bool == true}
        try await wait{try await js(web,"document.querySelector('table').rows[3].cells[3].querySelector('.formula-result')?.textContent==='36.58'") as? Bool == true}
        _=try await js(web,"window.folio.command('undo');true")
        try await wait{try await js(web,"window.folio.snapshot().text.includes('`=ROUND(B2*C2,2)`') && !window.folio.snapshot().text.includes('C2*2')") as? Bool == true}
        print("PASS: formula changes preserve literal operators and native undo restores the formula")
        let api=AssistantService(book)
        func call(_ name:String,_ args:[String:Any])async throws->[String:Any]{
            let response:[String:Any]=await withCheckedContinuation{c in api.handle(["name":name,"arguments":args]){c.resume(returning:$0)}}
            guard response["isError"] as? Bool == false else{throw TaskPageError(String(describing:response))};return response["structuredContent"] as! [String:Any]
        }
        let result=try await call("evaluate_formula",["path":note.path,"table":"Estimate","formula":"=ROUND(SUM(D2:D3)*1.18,2)"])
        try require(result["value"] as? String == "33.04","MCP and visible editor use the same decimal engine and current source revisions")
        _=try await js(web,"window.folio.load({id:window.folio.snapshot().id,text:window.folio.snapshot().text,reading:true,theme:'light'});true")
        try await wait{try await js(web,"document.querySelectorAll('.formula-result').length===4 && document.querySelector('table').rows[3].cells[3].querySelector('.formula-result')?.textContent==='33.04'") as? Bool == true}
        try require(try await js(web,"window.formulaErrors.length===0 && document.querySelector('.tiptap').getAttribute('contenteditable')==='false'") as? Bool == true,"formula projections also work in read-only mode without script errors")
        let light=try await web.takeSnapshot(configuration:nil)
        if let data=light.tiffRepresentation,let bitmap=NSBitmapImageRep(data:data){try bitmap.representation(using:.png,properties:[:])?.write(to:out.appendingPathComponent("table-formulas-light.png"))}
        window.orderOut(nil)
    }
}
