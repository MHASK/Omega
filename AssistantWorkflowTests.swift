import Foundation

@MainActor func runAgentWorkflowTests() throws {
    let base = FileManager.default.temporaryDirectory.appendingPathComponent("Omega-workflow-" + UUID().uuidString), root = base.appendingPathComponent("Notes")
    try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
    defer { try? FileManager.default.removeItem(at:base) }
    let store = Notebook(recovery:DraftRecovery(directory:base.appendingPathComponent("Recovery"))); store.root=root; store.notebooks=[root]
    let service = AssistantService(store,history:base.appendingPathComponent("History"))
    func call(_ name: String, _ args: [String:Any], error: String? = nil) -> [String:Any] {
        var response: [String:Any]?
        service.handle(["name":name,"arguments":args]) { response=$0 }
        guard let response else { preconditionFailure("No response") }
        if let error {
            precondition(response["isError"] as? Bool == true && String(describing:response).contains(error), "\(name): \(response)")
            return [:]
        }
        precondition(response["isError"] as? Bool == false,"\(name): \(response)")
        return response["structuredContent"] as! [String:Any]
    }
    let page=call("create_task_page",["folder":root.path,"name":"Workflow"]),path=page["path"] as! String
    let created=call("edit_tasks",["path":path,"operations":[
        ["op":"add","title":"Merged dependency","client_id":"merged"],
        ["op":"add","title":"Agent task","client_id":"agent"],
        ["op":"add","title":"Human task","labels":["you"],"client_id":"human"]]])["created"] as! [String:String]
    func read(_ key: String) -> [String:Any] { call("read_task",["path":path,"task_id":created[key]!]) }
    func target(_ key: String, _ extra: [String:Any] = [:]) -> [String:Any] {
        let task=read(key);return ["path":path,"task_id":created[key]!,"expected_task_revision":task["task_revision"]!].merging(extra){_,v in v}
    }
    var latest=call("read_task_page",["path":path])
    _=call("configure_task_statuses",["path":path,"expected_revision":latest["revision"]!,"statuses":["To do","In progress","Merged","Done"],"completed_status":"Done","completed_statuses":["Done","Merged"]])
    _=call("update_task",target("merged",["status":"Merged"]))
    _=call("set_task_dependencies",target("agent",["dependencies":["Workflow.md#"+created["merged"]!]]))
    let queue=call("read_work_queue",["path":root.path,"state":"ready"])["tasks"] as! [[String:Any]]
    precondition(queue.count==1 && queue[0]["id"] as? String==created["agent"],"Merged unblocks, YOU excluded")
    precondition((call("read_work_queue",["path":root.path,"state":"done"])["tasks"] as! [[String:Any]]).count==1)
    precondition((call("read_work_queue",["path":root.path,"audience":"human"])["tasks"] as! [[String:Any]]).count==1)
    _=call("claim_task",target("human",["owner":"Agent"]),error:"not Ready")
    _=call("update_task",["path":path,"task_id":created["agent"]!,"title":"Missing"],error:"Missing expected_task_revision")
    _=call("configure_task_work",target("human",["audience":"agent"]))
    precondition((call("read_work_queue",["path":root.path,"state":"ready"])["tasks"] as! [[String:Any]]).count==2)
    _=call("configure_task_work",target("human",["audience":"auto"]))
    let claim=call("claim_task",target("agent",["owner":"Agent A","lease_seconds":60])),token=claim["claim_token"] as! String
    let originalExpiry=read("agent")["claim_expires_at"] as! String
    _=call("renew_task_claim",target("agent",["claim_token":token,"lease_seconds":600]))
    precondition((read("agent")["claim_expires_at"] as! String)>originalExpiry)
    _=call("renew_task_claim",target("agent",["claim_token":"wrong"]),error:"receipt")
    _=call("configure_task_work",target("agent",["claim_token":token,"handoff":"Preserve partial work","branch":"agent-a"]))
    _=call("update_task",target("agent",["claim_token":token,"status":"In progress"]))
    // Expire deterministically without sleeping or touching a real notebook.
    var doc=try TaskDocument(markdown:String(contentsOfFile:path,encoding:.utf8))
    let ref=doc.references.first{$0.details.id==created["agent"]}!.reference
    try doc.updateDetails(ref) { d in var claim=TaskCoordination.claim(d)!;claim["expires"] = .number(Date().timeIntervalSince1970-1);d.extra["omegaClaim"] = .object(claim) }
    try doc.markdown.write(toFile:path,atomically:true,encoding:.utf8)
    let recoverable=call("read_work_queue",["path":root.path,"state":"recoverable"])["tasks"] as! [[String:Any]]
    precondition(recoverable.count==1 && recoverable[0]["status"] as? String=="In progress")
    _=call("update_task",target("agent",["claim_token":token,"title":"Zombie write"]),error:"expired")
    _=call("renew_task_claim",target("agent",["claim_token":token]),error:"expired")
    let reclaimed=call("claim_task",target("agent",["owner":"Agent B"])),newToken=reclaimed["claim_token"] as! String
    precondition(newToken != token && (read("agent")["details"] as! [String:Any])["omegaHandoff"] as? String=="Preserve partial work")
    _=call("update_task",target("agent",["claim_token":token,"title":"Old owner"]),error:"receipt")
    _=call("handoff_task",target("agent",["claim_token":newToken,"handoff":"Reviewed existing work","needs_review":false]))
    // Editing another row through a folder must not turn Merged into Done.
    let source=try FolderTaskSource(url:URL(fileURLWithPath:path),text:String(contentsOfFile:path,encoding:.utf8),preferences:TaskPreferences())
    let snapshot=try FolderTaskSnapshot(folder:root,sources:[source],preferences:TaskPreferences())
    var proposal=snapshot.document;proposal.tasks[proposal.tasks.firstIndex{$0.title=="Human task"}!].title="Human task changed"
    let edits=try snapshot.edits(proposal)
    let after=try TaskDocument(markdown:edits[0].after)
    precondition(after.tasks.first{$0.title=="Merged dependency"}?.status=="Merged" && after.completedStatuses==["Done","Merged"])
    latest=call("read_task_page",["path":path])
    precondition((latest["tasks"] as! [[String:Any]]).first{$0["id"] as? String==created["merged"]}?["completed"] as? Bool==true)
    _=call("configure_task_statuses",["path":path,"expected_revision":latest["revision"]!,"statuses":["To do","In progress","Merged","Done"],"completed_status":"Done","completed_statuses":["Merged"]],error:"include completed_status")
    print("PASS: multi-status completion and dependencies, human/agent separation, missing-revision diagnostic, expiring/renewable/recoverable claims, zombie-write rejection, and folder status preservation")
}
