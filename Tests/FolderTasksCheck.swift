import Foundation

#if SWIFT_PACKAGE
@testable import OmegaCore
#endif

#if FOLDER_TASK_CHECK
@main
#endif
struct FolderTasksCheck {
    static func require(_ value: @autoclosure () throws -> Bool, _ message: String) throws {
        if try !value() { throw TaskPageError(message) }; print("PASS:", message)
    }
    static func main() throws {
        let root = URL(fileURLWithPath: "/tmp/OmegaFolderFixture/Studio")
        let preferences = TaskPreferences()
        let a = try FolderTaskSource(url: root.appendingPathComponent("Launch.md"), text: """
        <!-- folio:tasks -->
        # Launch
        ## Goals
        - [ ] Ship the release
          <!-- folio:task {"id":"goal-shared"} -->
        ## To do
        - [ ] Design the next chapter
          <!-- folio:task {"id":"duplicate","description":"Keep **this** description","labels":["design"],"vendor":{"keep":true}} -->
          - [ ] Review the details
            <!-- folio:task {"id":"child"} -->
        ## In progress
        ## Done
        """, preferences: preferences)
        let b = try FolderTaskSource(url: root.appendingPathComponent("Projects/Delivery.md"), text: """
        <!-- folio:tasks -->
        <!-- folio:completed "Shipped" -->
        # Delivery
        ## Goals
        ## Waiting
        - [ ] Share with everyone
          <!-- folio:task {"id":"duplicate","due":"2026-11-01"} -->
        ## Building
        ## Shipped
        """, preferences: preferences)
        let plain = "# Field notes 🪴\r\n\r\nKeep this introduction.\r\n\r\n- [ ] Talk to a friend\r\n  - [x] Prepare questions\r\n\r\n| Name | Value |\r\n| --- | --- |\r\n| Keep | exact |\r\n\r\n- [ ] A separate checklist\r\n\r\n```md\r\n- [ ] Example, not a task\r\n```\r\n"
        let c = try FolderTaskSource(url: root.appendingPathComponent("Field notes.md"), text: plain, preferences: preferences)
        let snapshot = try FolderTaskSnapshot(folder: root, sources: [a,b,c], preferences: preferences)
        try require(snapshot.document.tasks.count == 4, "folder gathers both task pages and inline checklists")
        try require(Set(snapshot.document.references.compactMap { $0.details.id }).count == snapshot.document.references.count, "copied task IDs remain distinct across pages")
        try require(snapshot.document.statuses.contains("Waiting") && snapshot.document.statuses.contains("Building"), "custom statuses join the folder workflow")
        var proposal = try TaskDocument(markdown: snapshot.document.markdown)
        try require(try snapshot.edits(proposal).isEmpty, "opening the aggregate does not rewrite any source page")
        let bIndex = proposal.tasks.firstIndex { $0.title == "Share with everyone" }!
        proposal.tasks[bIndex].status = proposal.completedStatus
        var edits = try snapshot.edits(proposal)
        try require(edits.count == 1 && edits[0].url == b.url, "a board move edits only its source page")
        let savedB = try TaskDocument(markdown: edits[0].after)
        try require(savedB.tasks[0].status == "Shipped" && savedB.tasks[0].details.due == "2026-11-01", "completion maps back to the page’s custom completed status")
        proposal = try TaskDocument(markdown: snapshot.document.markdown)
        let cIndex = proposal.tasks.firstIndex { $0.title == "Talk to a friend" }!
        proposal.tasks[cIndex].status = "In progress"
        proposal.tasks[cIndex].details.description = "Follow up **tomorrow**."
        proposal.tasks[cIndex].details.labels = ["research"]
        edits = try snapshot.edits(proposal)
        try require(edits.count == 1 && edits[0].url == c.url, "inline task details save back to the original note")
        let updatedPlain = edits[0].after
        try require(updatedPlain.contains("| Name | Value |\r\n| --- | --- |\r\n| Keep | exact |"), "table bytes and CRLF are preserved")
        try require(updatedPlain.contains("- [ ] A separate checklist\r\n") && updatedPlain.contains("```md\r\n- [ ] Example, not a task\r\n```"), "unrelated checklist lines and fenced code are untouched")
        let updatedC = try FolderTaskSource(url: c.url, text: updatedPlain, preferences: preferences)
        try require(updatedC.document.tasks[0].status == "In progress" && updatedC.document.tasks[0].details.labels == ["research"], "rich inline details survive reopening")
        let roundtrip = try FolderTaskSnapshot(folder: root, sources: [a,b,updatedC], preferences: preferences)
        try require(roundtrip.document.tasks.first { $0.title == "Talk to a friend" }?.details.id == snapshot.document.tasks.first { $0.title == "Talk to a friend" }?.details.id, "legacy inline identities become durable without jumping selection")
        try require(try roundtrip.edits(TaskDocument(markdown: roundtrip.document.markdown)).isEmpty, "saved inline tasks reopen without another write")
        proposal = try TaskDocument(markdown: snapshot.document.markdown)
        proposal.tasks[bIndex].details.goals = [proposal.goals[0].details.id!]
        edits = try snapshot.edits(proposal)
        try require(edits.count == 1 && edits[0].url == b.url, "cross-page goal linking changes only the linked task’s page")
        let linkedB = try FolderTaskSource(url: b.url, text: edits[0].after, preferences: preferences)
        try require(linkedB.document.tasks[0].details.goals?.count == 1 && linkedB.document.tasks[0].details.extra["omegaGoalSources"] != nil, "saved goal links retain the original goal identity")
        let linked = try FolderTaskSnapshot(folder: root, sources: [a,linkedB,c], preferences: preferences)
        try require(linked.document.goalProgress(linked.document.goals[0]).linked.count == 1, "folder goals resolve links across pages after reopening")
        proposal = try TaskDocument(markdown: linked.document.markdown)
        let gi = proposal.goals[0].details.id!
        let linkedIndex = proposal.tasks.firstIndex { ($0.details.goals ?? []).contains(gi) }!
        proposal.tasks[linkedIndex].status = proposal.completedStatus
        try require(proposal.goalProgress(proposal.goals[0]).completed == 1, "goal progress follows linked task completion")
        edits = try linked.edits(proposal)
        try require(edits.first { $0.url == b.url } != nil, "linked completion produces a source edit")
        proposal = try TaskDocument(markdown: snapshot.document.markdown)
        let nested = proposal.tasks.firstIndex { $0.title == "Design the next chapter" }!
        proposal.tasks[nested].subtasks[0].details.description = "Keep me"
        let childID = proposal.tasks[nested].subtasks[0].details.id!
        try proposal.moveTask(id: childID, parentID: nil)
        edits = try snapshot.edits(proposal)
        let promoted = try TaskDocument(markdown: edits[0].after)
        try require(promoted.tasks.contains { $0.details.id == "child" && $0.details.description == "Keep me" }, "task-page promotion keeps all details")
        proposal = try TaskDocument(markdown: snapshot.document.markdown)
        proposal.tasks[0].details.extra["_folderSource"] = .string("unknown")
        do { _ = try snapshot.edits(proposal); throw TaskPageError("Accepted an unknown source") } catch { try require(!error.localizedDescription.contains("Accepted"), "unknown destinations are rejected before writing") }
        let incomplete = "- [ ] Work <!-- omega-task: {broken} -->\n"
        do { _ = try FolderTaskSource(url: c.url, text: incomplete, preferences: preferences); throw TaskPageError("Accepted broken metadata") } catch { try require(!error.localizedDescription.contains("Accepted"), "malformed inline details are never silently replaced") }
        proposal = try TaskDocument(markdown: snapshot.document.markdown)
        let inlineParent = proposal.tasks.first { $0.title == "Talk to a friend" }!
        let secondInline = proposal.tasks.first { $0.title == "A separate checklist" }!
        try proposal.moveTask(id: inlineParent.subtasks[0].details.id!, parentID: secondInline.details.id!)
        edits = try snapshot.edits(proposal)
        let movedInline = try InlineTaskDocument(edits[0].after, preferences: preferences)
        try require(movedInline.document.tasks.first { $0.title == "A separate checklist" }?.subtasks.first?.title == "Prepare questions", "inline subtasks can move between checklists without becoming copies")
        try require(edits[0].after.contains("| Name | Value |\r\n| --- | --- |\r\n| Keep | exact |"), "moving an inline subtask preserves intervening prose and tables")
        proposal = try TaskDocument(markdown: snapshot.document.markdown)
        let newID = UUID().uuidString.lowercased()
        let extra: [String: TaskJSON] = ["_folderSource": .string(c.key), "_folderID": .string(newID)]
        var d = TaskDetails(); d.id = FolderTaskSnapshot.identity(c.key, newID); d.extra = extra; d.status = "To do"
        proposal.tasks[proposal.tasks.firstIndex { $0.title == "Talk to a friend" }!].subtasks.append(TaskCheckItem(title: "A new small step", details: d))
        edits = try snapshot.edits(proposal)
        let addedInline = try InlineTaskDocument(edits[0].after, preferences: preferences)
        try require(addedInline.document.tasks.first { $0.title == "Talk to a friend" }?.subtasks.count == 2, "new inline subtasks are inserted beneath their actual parent")
        try require(edits[0].after.contains("Keep this introduction."), "creating a subtask preserves the original note")
        let legacyGoal = try FolderTaskSource(url: a.url, text: a.text.replacingOccurrences(of: "  <!-- folio:task {\"id\":\"goal-shared\"} -->\n", with: ""), preferences: preferences)
        let legacySnapshot = try FolderTaskSnapshot(folder: root, sources: [legacyGoal,b], preferences: preferences)
        var legacyProposal = try TaskDocument(markdown: legacySnapshot.document.markdown)
        legacyProposal.tasks[legacyProposal.tasks.firstIndex { $0.title == "Share with everyone" }!].details.goals = [legacyProposal.goals[0].details.id!]
        let legacyEdits = try legacySnapshot.edits(legacyProposal)
        try require(legacyEdits.count == 2 && TaskDocument(markdown: legacyEdits.first { $0.url == a.url }!.after).goals[0].details.id != nil, "cross-page links establish durable identities for legacy goals")
        let relocated = URL(fileURLWithPath: "/tmp/AnotherMac/Studio")
        let movedSources = try legacySnapshot.sources.map { source in try FolderTaskSource(url: relocated.appendingPathComponent(FolderTaskSnapshot.relative(source.url, from: root)), text: legacyEdits.first { $0.url == source.url }?.after ?? source.text, preferences: preferences) }
        let onAnotherMac = try FolderTaskSnapshot(folder: relocated, sources: movedSources, preferences: preferences)
        try require(onAnotherMac.document.goalProgress(onAnotherMac.document.goals[0]).linked.count == 1, "Git clones on a different Mac preserve cross-page goal links")
        print("PASS: full folder task projection and lossless source edits")
    }
}
