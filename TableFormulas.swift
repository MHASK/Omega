import Foundation
import JavaScriptCore
import CryptoKit

// All calculations use the same bundled decimal engine as the editor. The only
// host callback is a bounded, read-only lookup inside explicitly open notebooks.
enum TableCalculation {
    struct Failure: LocalizedError { let message: String; var errorDescription: String? { message } }
    static func safeURL(_ path: String, from: URL, roots: [URL]) throws -> URL {
        guard !path.contains("\0"), path.count <= 4096, !path.hasPrefix("//"),
              path.range(of: "^[a-z][a-z0-9+.-]*:", options: [.regularExpression,.caseInsensitive]) == nil else { throw Failure(message:"Only local note paths are supported.") }
        // Foundation's standardization follows symlinks when a path contains
        // "..". Normalize components lexically before checking the actual files.
        let absolute = path.hasPrefix("/") ? path : from.deletingLastPathComponent().path + "/" + path
        var components:[Substring]=[]
        for component in absolute.split(separator:"/") {
            if component==".." { if !components.isEmpty { components.removeLast() } }
            else if component != "." { components.append(component) }
        }
        let url = URL(fileURLWithPath:"/"+components.joined(separator:"/"))
        guard let root = roots.filter({ url.path.hasPrefix($0.standardizedFileURL.path + "/") }).max(by: { $0.path.count < $1.path.count })?.standardizedFileURL else { throw Failure(message:"Source page is outside the open notebooks.") }
        guard ["md","markdown","txt"].contains(url.pathExtension.lowercased()) else { throw Failure(message:"Formula sources must be Markdown or text notes.") }
        var part=url
        while part.path != root.path {
            guard !part.lastPathComponent.hasPrefix("."), try part.resourceValues(forKeys:[.isSymbolicLinkKey]).isSymbolicLink != true else { throw Failure(message:"Hidden paths and symlinks cannot be formula sources.") }
            part.deleteLastPathComponent()
        }
        guard url.resolvingSymlinksInPath().path.hasPrefix(root.resolvingSymlinksInPath().path + "/") else { throw Failure(message:"Source escapes its notebook.") }
        let info=try url.resourceValues(forKeys:[.isRegularFileKey,.fileSizeKey])
        guard info.isRegularFile == true, (info.fileSize ?? 0) <= 2_000_000 else { throw Failure(message:"A formula source must be a regular note of at most 2 MB.") }
        return url
    }
    static func resource(_ name:String, _ ext:String)->URL? {
        if CommandLine.arguments.contains("--mcp-test"), let root=ProcessInfo.processInfo.environment["OMEGA_TEST_RESOURCES"] { return URL(fileURLWithPath:root).appendingPathComponent(name+"."+ext) }
        return Bundle.main.url(forResource:name,withExtension:ext)
    }
    static func hash(_ text:String)->String { SHA256.hash(data:Data(text.utf8)).map{String(format:"%02x",$0)}.joined() }
    static func run(source: URL, markdown: String, roots: [URL], selected: URL? = nil, selectedText: String = "", table: String? = nil, formula: String? = nil, script: String? = nil) throws -> [String:Any] {
        guard markdown.utf8.count<=2_000_000 else { throw Failure(message:"A formula page supports at most 2 MB.") }
        let code: String
        if let script { code=script }
        else { guard let file=resource("table-formulas","js") else { throw Failure(message:"Formula engine is unavailable. Reinstall the current Omega release.") }; code=try String(contentsOf:file,encoding:.utf8) }
        guard let context=JSContext() else { throw Failure(message:"Could not start the formula engine.") }
        var failure: String?, cache:[String:String]=[source.path:markdown]
        context.exceptionHandler={_,error in failure=error?.toString() ?? "Calculation failed."}
        let read: @convention(block) (String,String)->[String:Any] = { from,path in
            do {
                let url=try safeURL(path,from:URL(fileURLWithPath:from),roots:roots)
                let text: String
                if let saved=cache[url.path] { text=saved }
                else {
                    guard cache.count<32 else { throw Failure(message:"A calculation can read at most 32 pages.") }
                    text=url==selected ? selectedText : try String(contentsOf:url,encoding:.utf8)
                    guard text.utf8.count<=2_000_000, cache.values.reduce(0,{$0+$1.utf8.count})+text.utf8.count<=8_000_000 else { throw Failure(message:"Formula sources exceed the 8 MB calculation limit.") }
                    cache[url.path]=text
                }
                return ["path":url.path,"markdown":text]
            }catch{return ["error":error.localizedDescription]}
        }
        context.setObject(read,forKeyedSubscript:"omegaReadPage" as NSString)
        context.evaluateScript(code)
        guard failure==nil else { throw Failure(message:failure!) }
        let host=context.objectForKeyedSubscript("omegaReadPage")!
        let engine=context.objectForKeyedSubscript("OmegaFormula")!
        let selector:Any = (table.flatMap(Int.init).map { $0 as Any }) ?? (table as Any? ?? 1)
        let value:JSValue?
        if let formula { value=engine.objectForKeyedSubscript("calculateExpression")?.call(withArguments:[source.path,markdown,selector,formula,host]) }
        else { value=engine.objectForKeyedSubscript("calculatePage")?.call(withArguments:[source.path,markdown,host]) }
        guard failure==nil, var result=value?.toDictionary() as? [String:Any] else { throw Failure(message:failure ?? "Calculation returned an invalid result.") }
        result["revision"]=hash(markdown)
        result["source_revisions"]=cache.map{["path":$0.key,"revision":hash($0.value)]}.sorted{ $0["path"]! < $1["path"]! }
        return result
    }
    static func tableResponse(_ full:[String:Any], selector:String?, offset:Int, limit:Int) throws -> [String:Any] {
        if full["error"] != nil { return full }
        let tables=full["tables"] as? [[String:Any]] ?? []
        var result:[String:Any] = ["path":full["path"] ?? NSNull(),"revision":full["revision"] ?? NSNull(),"source_revisions":full["source_revisions"] ?? NSNull()]
        guard let selector else {
            result["tables"]=tables.map { t -> [String:Any] in
                let rows=t["rows"] as? [[[String:Any]]] ?? []
                return ["index":t["index"] ?? NSNull(),"name":t["name"] ?? NSNull(),"headers":t["headers"] ?? NSNull(),"data_rows":max(0,rows.count-1),"formula_count":rows.flatMap{$0}.filter{($0["source"] as? String)?.hasPrefix("=") == true}.count]
            }
            result["hint"]="Pass table (its index as a string or unique heading) to read paginated cell values. A1 is the header row. Use evaluate_formula for calculations."
            return result
        }
        let matches=tables.filter{ t in Int(selector).map{t["index"] as? Int == $0} ?? (t["name"] as? String == selector) }
        guard matches.count==1, var table=matches.first else { throw Failure(message:"Table is missing or its heading is ambiguous. Call read_tables without table to discover table indices.") }
        let rows=table["rows"] as? [[[String:Any]]] ?? [], start=max(0,offset), size=min(100,max(1,limit))
        table["rows"]=Array(rows.dropFirst(start).prefix(size));table["total_rows"]=rows.count
        table["next_offset"]=start+size<rows.count ? (start+size as Any) : NSNull()
        result["table"]=table;return result
    }
}

extension AssistantService {
    func calculateTables(_ name:String, _ args:[String:Any], completion:@escaping ([String:Any])->Void) throws {
        let url=try resolve(string(args,"path"),folder:false)
        let roots=notebook.roots, selected=notebook.selected, selectedText=notebook.text
        let table=args["table"] as? String, formula=args["formula"] as? String
        DispatchQueue.global(qos:.userInitiated).async {
            let response:[String:Any]
            do {
                _ = try TableCalculation.safeURL(url.path,from:url,roots:roots)
                let text=url==selected ? selectedText : try String(contentsOf:url,encoding:.utf8)
                let full=try TableCalculation.run(source:url,markdown:text,roots:roots,selected:selected,selectedText:selectedText,table:table,formula:formula)
                let result=name=="read_tables" ? try TableCalculation.tableResponse(full,selector:table,offset:args["offset"] as? Int ?? 0,limit:args["limit"] as? Int ?? 30) : full
                response=FolioMCP.success(result)
            }catch{response=FolioMCP.failure(error.localizedDescription)}
            DispatchQueue.main.async{completion(response)}
        }
    }
}
