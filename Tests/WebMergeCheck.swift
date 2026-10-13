import AppKit
import WebKit

@main struct WebMergeCheck {
    @MainActor static func main() {
        _ = NSApplication.shared; NSApp.setActivationPolicy(.prohibited); setbuf(stdout, nil)
        Task { @MainActor in do { try await run(); exit(0) } catch { print("FAIL",error); exit(1) } }; NSApp.run()
    }
    @MainActor final class Messages: NSObject, WKScriptMessageHandler {
        var values: [[String:Any]] = []
        func userContentController(_ c: WKUserContentController, didReceive message: WKScriptMessage) { if let v = message.body as? [String:Any] { values.append(v) } }
    }
    @MainActor static func run() async throws {
        let root = URL(fileURLWithPath: CommandLine.arguments[1]), fixture = URL(fileURLWithPath: CommandLine.arguments[2]), output = URL(fileURLWithPath:CommandLine.arguments[3])
        let configuration = WKWebViewConfiguration(), handler = Messages(); configuration.userContentController.add(handler, name: "review")
        let web = WKWebView(frame: NSRect(x:0,y:0,width:1100,height:730), configuration:configuration)
        let window = NSWindow(contentRect:web.frame,styleMask:[.titled,.resizable],backing:.buffered,defer:false);window.contentView=web;window.isReleasedWhenClosed=false
        web.loadFileURL(root.appendingPathComponent("git-review.html"),allowingReadAccessTo:root)
        for _ in 0..<100 { if (try? await web.evaluateJavaScript("typeof window.omegaReview")) as? String == "object" { break };try await Task.sleep(for:.milliseconds(60)) }
        var config = try JSONSerialization.jsonObject(with:Data(contentsOf:fixture)) as! [String:Any];config["editable"]=true
        func js(_ s:String) async throws -> Any? { try await web.evaluateJavaScript(s) }
        func check(_ condition:Bool,_ title:String) throws { guard condition else { throw NSError(domain:title,code:1) };print("PASS: " + title) }
        func open(_ c:[String:Any]) async throws { _ = try await web.callAsyncJavaScript("omegaReview.open(config);omegaReview.configure(true,false)",arguments:["config":c],in:nil,contentWorld:.page) }
        func snapshot(_ name:String) async throws { try await Task.sleep(for:.milliseconds(200));let image = try await web.takeSnapshot(configuration:nil);let rep=NSBitmapImageRep(data:image.tiffRepresentation!)!;try rep.representation(using:.png,properties:[:])!.write(to:output.appendingPathComponent(name)) }
        try await open(config)
        try check(try await js("document.querySelector('#save').disabled") as? Bool == true,"unresolved conflicts cannot be silently saved")
        _ = try await js("document.querySelector('#useCurrent').click();document.querySelector('#next').click();document.querySelector('#useIncoming').click()")
        let merged = try await js("document.querySelector('#result').value") as! String
        try check(merged.contains("Ship Tuesday.") && merged.contains("Budget 15.") && !merged.contains("Budget 12."),"per-conflict choices compose the chosen lines, preserving context")
        _ = try await js("document.querySelector('#save').click()")
        try await Task.sleep(for:.milliseconds(60))
        try check(handler.values.last?["text"] as? String == merged && handler.values.last?["choice"] as? String == "edited","Mark resolved sends exactly the reviewed result")
        // The review opens on the full Git diff.
        try check(try await js("document.querySelector('#diff').textContent.includes('@@') && document.querySelectorAll('.diffrow').length>4") as? Bool == true,"full file comparison renders actual Git hunks and line numbers")
        try await snapshot("git-review-split.png")
        _ = try await js("document.querySelector('[data-mode=unified]').click()")
        try check(try await js("document.querySelector('#diff').classList.contains('unified')") as? Bool == true,"unified diff uses the same exact Git patch")
        try await snapshot("git-review-unified.png")
        _ = try await js("document.querySelector('#undo').click();document.querySelector('#result').dispatchEvent(new InputEvent('beforeinput'));document.querySelector('#result').value+='\\nA manual addition.\\n';document.querySelector('#result').dispatchEvent(new InputEvent('input'))")
        try check(try await js("document.querySelector('#save').disabled && document.querySelector('#useBoth').disabled") as? Bool == true,"manual edits cannot be overwritten by a later hunk choice or silently mark unresolved work complete")
        _ = try await js("document.querySelector('#acknowledge').click()")
        try await Task.sleep(for:.milliseconds(70))
        let draft = handler.values.last(where:{$0["kind"] as? String == "draft"})?["draft"] as! String
        config["draft"]=draft;try await open(config)
        try check(try await js("document.querySelector('#result').value.includes('A manual addition.') && !document.querySelector('#save').disabled") as? Bool == true,"persisted manual draft and explicit completion survive reopening")
        web.setFrameSize(NSSize(width:570,height:720));window.setContentSize(web.frame.size)
        try check(try await js("document.documentElement.scrollWidth === innerWidth") as? Bool == true,"narrow review stays within the window")
        try await snapshot("git-review-narrow.png")
        _ = try await js("omegaReview.configure(false,false)");try await snapshot("git-review-light.png")
        config["path"]="<script>alert(1)</script>.md";config["parts"]=[["current":"<img src=x onerror=alert(1)>","incoming":"Other","base":"Old"]];config.removeValue(forKey:"draft")
        try await open(config)
        try check(try await js("document.querySelector('#diff img')===null && document.querySelector('#filename').children.length===0") as? Bool == true,"file contents and filenames render as text, never executable markup")
        window.close();print("All merge editor checks passed.")
    }
}
