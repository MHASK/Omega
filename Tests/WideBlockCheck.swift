import AppKit
import WebKit

final class WidthCheck: NSObject, WKNavigationDelegate {
    var view: WKWebView!
    var widths = [144.0, 257.0, 380.0, 700.0, 1300.0]
    var done = false
    var failed = false
    func start() throws {
        _ = NSApplication.shared
        view = WKWebView(frame: NSRect(x: 0,y: 0,width: 1300,height: 850))
        view.navigationDelegate = self
        let css = try String(contentsOfFile: CommandLine.arguments[1], encoding: .utf8)
        let html = "<html><head><style>" + css + "</style></head><body><div id='scroller'><main id='editor'><div class='tiptap'><h1>Quiet writing</h1><p id='prose'>A narrow reading column with room for larger things.</p><div class='tableWrapper'><table><tr><td>First</td><td>Second</td><td>Third</td></tr></table></div><span class='image-block'><img width='1400' height='500'></span><blockquote><p>Nested image</p><span class='image-block' id='nested'><img width='1400' height='500'></span></blockquote></div></main></div></body></html>"
        view.loadHTMLString(html, baseURL: nil)
    }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { checkNext() }
    func checkNext() {
        guard !widths.isEmpty else { done = true; return }
        let width = widths.removeFirst(); view.frame.size.width = width
        view.evaluateJavaScript("new Promise(r=>requestAnimationFrame(()=>requestAnimationFrame(r)))") { _,_ in
            self.view.evaluateJavaScript("""
            (()=>{const box=s=>{const r=document.querySelector(s).getBoundingClientRect();return {x:r.x,width:r.width,right:r.right}};return {prose:box('#prose'),table:box('.tableWrapper'),image:box('.tiptap>.image-block'),nested:box('#nested'),pane:document.querySelector('#scroller').clientWidth,scroll:document.querySelector('#scroller').scrollWidth}})()
            """) { result,error in
                guard let data=result as? [String:Any],error==nil,let prose=data["prose"] as? [String:Double],let table=data["table"] as? [String:Double],let image=data["image"] as? [String:Double],let nested=data["nested"] as? [String:Double],let pane=data["pane"] as? Double,let scroll=data["scroll"] as? Double else {print("FAIL",error as Any);self.failed=true;self.done=true;return}
                let valid = prose["width"]! <= 651 && abs(table["x"]! + table["right"]! - pane) < 2 && image["width"]! <= 961 && image["width"]! < table["width"]! && table["x"]! >= 4 && table["x"]! <= 20 && pane-table["right"]! >= 4 && pane-table["right"]! <= 20 && nested["width"]! <= prose["width"]! && scroll <= pane+1 && (width < 900 || table["width"]! > prose["width"]!+200)
                print(valid ? "PASS" : "FAIL", "pane",width,"text",prose["width"]!,"wide",table["width"]!,"left/right",table["x"]!,pane-table["right"]!,"horizontal overflow",scroll-pane)
                self.failed = self.failed || !valid; self.checkNext()
            }
        }
    }
}
let check = WidthCheck()
do {try check.start()}catch {print(error);exit(1)}
let deadline=Date().addingTimeInterval(30)
while !check.done && Date()<deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.05)) }
exit(check.done && !check.failed ? 0 : 1)
