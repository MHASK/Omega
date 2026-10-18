import Foundation

// A small shell interface over the same local service as MCP. No second database.
enum AgentCLI {
    static let help = """
    Omega tasks · keep Omega open with assistant access enabled
      omega ready [notebook] [--label LABEL] [--priority 0-4] [--json]
      omega list [notebook] [--state STATE] [--audience agent|human] [--query TEXT] [--json]
      omega show /absolute/page.md TASK_ID
      omega call TOOL < arguments.json
    Notebook defaults to the nearest project's Omega workflow configuration.
    Queue flags: --status, --assignee, --limit, --offset, --expected-queue-revision.
    Mutations use `call` with exact task revisions and claim receipts on stdin.
    Claims last 30 minutes by default; renew_task_claim extends an active lease.
    All commands connect to this Mac's Omega service. They do not provide distributed locks.
    """
    static func request(_ name: String, _ args: [String: Any]) throws -> [String: Any] {
        let fd = try AssistantWire.connect(); defer { close(fd) }
        try AssistantWire.write(AssistantWire.json(["name":name,"arguments":args,"clientName":"Omega CLI","deadline":Date().timeIntervalSince1970+20]), to:fd)
        guard let result = try JSONSerialization.jsonObject(with: AssistantWire.read(fd)) as? [String: Any] else { throw AssistantError("Invalid response from Omega.") }
        if result["isError"] as? Bool == true { throw AssistantError((result["content"] as? [[String:Any]])?.first?["text"] as? String ?? "Omega could not complete the request.") }
        return result["structuredContent"] as? [String: Any] ?? [:]
    }
    static func notebookPath() throws -> String {
        var folder = URL(fileURLWithPath:FileManager.default.currentDirectoryPath)
        while true {
            let file = folder.appendingPathComponent("AGENTS.md")
            if let text = try? String(contentsOf:file, encoding:.utf8),
               let line = text.components(separatedBy:"\n").first(where:{$0.hasPrefix("Notebook configuration (data): ")}),
               let data = line.dropFirst("Notebook configuration (data): ".count).data(using:.utf8),
               let value = try? JSONSerialization.jsonObject(with:data) as? [String:Any], let path = value["notebook"] as? String { return path }
            if folder.path == "/" { break }; folder.deleteLastPathComponent()
        }
        throw AssistantError("Pass an open notebook path, or use Settings → Assistants → Set up project first.")
    }
    static func run(_ arguments: [String]) -> Int32 {
        do {
            guard let command = arguments.first, !["--help","help","-h"].contains(command) else { print(help); return 0 }
            if command == "call" {
                guard arguments.count == 2 else { throw AssistantError("Usage: omega call TOOL < arguments.json") }
                let data = FileHandle.standardInput.readDataToEndOfFile()
                guard data.count < AssistantWire.maximum, let args = try JSONSerialization.jsonObject(with:data) as? [String:Any] else { throw AssistantError("Pass a JSON object on stdin.") }
                print(String(decoding:AssistantWire.json(try request(arguments[1],args)),as:UTF8.self)); return 0
            }
            if command == "show" {
                guard arguments.count == 3 else { throw AssistantError("Usage: omega show /absolute/page.md TASK_ID") }
                print(String(decoding:AssistantWire.json(try request("read_task",["path":arguments[1],"task_id":arguments[2]])),as:UTF8.self)); return 0
            }
            guard ["ready","list"].contains(command) else { throw AssistantError("Unknown command. Run omega help.") }
            var args: [String:Any] = command == "ready" ? ["state":"ready","audience":"agent"] : [:], json = false, i = 1
            let names = ["--state":"state","--audience":"audience","--label":"label","--priority":"priority","--query":"query","--status":"status","--assignee":"assignee","--limit":"limit","--offset":"offset","--expected-queue-revision":"expected_queue_revision"]
            while i < arguments.count {
                let word = arguments[i]; i += 1
                if word == "--json" { json = true; continue }
                if let key = names[word] {
                    guard i < arguments.count else { throw AssistantError("Missing value for " + word) }
                    let value = arguments[i]; i += 1
                    if ["limit","offset","priority"].contains(key) { guard let n = Int(value) else { throw AssistantError("Expected a number for " + word) }; args[key] = n }
                    else { args[key] = value }
                } else if !word.hasPrefix("--") && args["path"] == nil { args["path"] = URL(fileURLWithPath:word).standardizedFileURL.path }
                else { throw AssistantError("Unexpected argument: " + word) }
            }
            if args["path"] == nil { args["path"] = try notebookPath() }
            let result = try request("read_work_queue",args)
            if json { print(String(decoding:AssistantWire.json(result),as:UTF8.self)); return 0 }
            func safe(_ value: Any?) -> String { String(describing:value ?? "").components(separatedBy:.controlCharacters).joined(separator:" ") }
            for row in result["tasks"] as? [[String:Any]] ?? [] {
                let priority = (row["priority"] as? Int).map { "P\($0)" } ?? "—"
                print("\(priority)  \(safe(row["state"]))  \(safe(row["title"]))\n    \(safe(row["path"]))#\(safe(row["id"]))")
            }
            print("\(result["total"] as? Int ?? 0) matching tasks.")
            if let offset = result["next_offset"] as? Int { print("More results: --offset \(offset). Use --json for queue_revision and exact task revisions.") }
            for warning in result["warnings"] as? [String] ?? [] { print("Warning: " + safe(warning)) }
            return 0
        } catch { FileHandle.standardError.write(Data((error.localizedDescription+"\n").utf8)); return 1 }
    }
    static func install() throws -> URL {
        let folder = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin"), file = folder.appendingPathComponent("omega")
        let executable = Bundle.main.executableURL!.path.replacingOccurrences(of:"'",with:"'\\''")
        let wrapper = "#!/bin/sh\n# Omega managed CLI\nexec '\(executable)' --agent \"$@\"\n"
        if FileManager.default.fileExists(atPath:file.path) {
            guard let old = try? String(contentsOf:file,encoding:.utf8), old.contains("# Omega managed CLI"), file.resolvingSymlinksInPath() == file else { throw AssistantError("An unrelated omega command already exists at " + file.path) }
        }
        try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
        try wrapper.write(to:file,atomically:true,encoding:.utf8)
        try FileManager.default.setAttributes([.posixPermissions:0o755],ofItemAtPath:file.path)
        return file
    }
}
