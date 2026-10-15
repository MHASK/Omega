import Foundation
#if SWIFT_PACKAGE
@testable import OmegaCore
#endif
struct NoteLinkCheck {
    static func main() throws {
        let fm=FileManager.default
        let base=fm.temporaryDirectory.appendingPathComponent("Folio-Links-"+UUID().uuidString).resolvingSymlinksInPath()
        defer {try? fm.removeItem(at:base)}
        let root=base.appendingPathComponent("Notes"), other=base.appendingPathComponent("Other")
        try fm.createDirectory(at:root.appendingPathComponent("Drafts"),withIntermediateDirectories:true)
        try fm.createDirectory(at:other,withIntermediateDirectories:true)
        let source=root.appendingPathComponent("Drafts/Start.md")
        let paths=[root.appendingPathComponent("Decision log.md"),other.appendingPathComponent("Café (plan) #1 %.md"),root.appendingPathComponent("Drafts/Next.markdown")]
        for target in paths {
            try "# Target".write(to:target,atomically:true,encoding:.utf8)
            let href=NoteLinks.href(from:source,to:target)
            precondition(NoteLinks.resolve(href,from:source,roots:[root,other])==target)
        }
        precondition(NoteLinks.resolve(NoteLinks.href(from:source,to:paths[1]),from:source,roots:[root])==nil)
        for href in ["https://example.com/a.md","//host/a.md","../../../outside.md","missing.md","./%XX.md"] {
            precondition(NoteLinks.resolve(href,from:source,roots:[root,other])==nil)
        }
        let symlink=root.appendingPathComponent("Link.md")
        try fm.createSymbolicLink(at:symlink,withDestinationURL:paths[1])
        precondition(NoteLinks.resolve("../Link.md",from:source,roots:[root,other])==nil)
        print("PASS: local and cross-notebook paths, Unicode and reserved characters, missing/closed targets, external URLs and symlink rejection")
    }
}

#if !SWIFT_PACKAGE
@main struct NoteLinkCheckMain { static func main() throws { try NoteLinkCheck.main() } }
#endif
