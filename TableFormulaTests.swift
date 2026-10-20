import Foundation

@MainActor func runTableFormulaTests() throws {
    func check(_ condition:Bool,line:Int=#line)throws{if !condition{throw TableCalculation.Failure(message:"Formula check failed at line \(line)")}}
    let fm=FileManager.default, base=fm.temporaryDirectory.appendingPathComponent("Omega-formulas-"+UUID().uuidString)
    let root=base.appendingPathComponent("Book"), other=base.appendingPathComponent("Other"), sub=root.appendingPathComponent("Plans")
    try fm.createDirectory(at:sub,withIntermediateDirectories:true);try fm.createDirectory(at:other,withIntermediateDirectories:true)
    defer{try? fm.removeItem(at:base)}
    let rates=root.appendingPathComponent("Rates.md"), quote=sub.appendingPathComponent("Quote.md")
    let markdown="# Quote\n\n| Name | Total |\n| --- | --- |\n| API | `=CELL(\"../Rates.md\",\"Rates\",\"API\",\"Price\")*10` |\n"
    let price="# Rates\n\n| Name | Price |\n| --- | --- |\n| API | `=0.1+0.2` |\n"
    try price.write(to:rates,atomically:true,encoding:.utf8);try markdown.write(to:quote,atomically:true,encoding:.utf8)
    func calc(_ expression:String, roots:[URL]?=nil) throws->[String:Any] { try TableCalculation.run(source:quote,markdown:markdown,roots:roots ?? [root],formula:expression) }
    try check(calc("=B2")["value"] as? String == "3")
    let changed=price.replacingOccurrences(of:"0.1+0.2",with:"0.2+0.3");try changed.write(to:rates,atomically:true,encoding:.utf8)
    try check(calc("=B2")["value"] as? String == "5")
    let draft=try TableCalculation.run(source:quote,markdown:markdown,roots:[root],selected:rates,selectedText:price,formula:"=B2")
    try check(draft["value"] as? String == "3")
    let outside=other.appendingPathComponent("Rates.md");try price.write(to:outside,atomically:true,encoding:.utf8)
    try check(calc("=CELL(\"../../Other/Rates.md\",1,\"B2\")")["error"] as? String == "#REF!")
    try check(calc("=CELL(\"../../Other/Rates.md\",1,\"B2\")",roots:[root,other])["value"] as? String == "0.3")
    let hidden=root.appendingPathComponent(".private");try fm.createDirectory(at:hidden,withIntermediateDirectories:true);try price.write(to:hidden.appendingPathComponent("Rates.md"),atomically:true,encoding:.utf8)
    try check(calc("=CELL(\"../.private/Rates.md\",1,\"B2\")")["error"] as? String == "#REF!")
    try fm.createSymbolicLink(at:root.appendingPathComponent("Link.md"),withDestinationURL:rates)
    try check(calc("=CELL(\"../Link.md\",1,\"B2\")")["error"] as? String == "#REF!")
    let missing=try calc("=CELL(\"missing.md\",1,\"B2\")");precondition(missing["error"] as? String == "#REF!")
    let store=Notebook(recovery:DraftRecovery(directory:base.appendingPathComponent("Recovery")));store.root=root;store.notebooks=[root]
    let service=AssistantService(store,history:base.appendingPathComponent("History"))
    func call(_ name:String,_ args:[String:Any]=[:])->[String:Any] {
        var response:[String:Any]?
        service.handle(["name":name,"arguments":args]){response=$0}
        let deadline=Date().addingTimeInterval(10)
        while response==nil && Date()<deadline { RunLoop.main.run(until:Date().addingTimeInterval(0.01)) }
        precondition(response?["isError"] as? Bool == false,"Formula tool failed: \(String(describing:response))")
        return response!["structuredContent"] as! [String:Any]
    }
    let discovery=call("read_tables",["path":quote.path]);precondition((discovery["tables"] as? [[String:Any]])?.count==1)
    let cells=call("read_tables",["path":quote.path,"table":"1","offset":1,"limit":1])["table"] as! [String:Any]
    try check((cells["rows"] as! [[[String:Any]]])[0][1]["value"] as? String == "5")
    try check(call("evaluate_formula",["path":quote.path,"formula":"=ROUND(B2*1.18,2)"])["value"] as? String == "5.9")
    try check((call("get_changelog")["markdown"] as? String)?.contains("evaluate_formula") == true)
    try check(String(contentsOf:quote,encoding:.utf8)==markdown)
    print("PASS: native decimal engine; cross-folder/open-notebook resolution; external refresh; unsaved source snapshot; hidden/symlink/outside rejection; paginated MCP read_tables/evaluate_formula; changelog discovery; no source writes")
}
