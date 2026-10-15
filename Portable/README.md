# Linux parity work

Status: shared data services, not a released desktop app. Do not add a Linux download link until every desktop requirement below has been implemented and verified on Linux.

The Mac app remains SwiftUI/AppKit and uses its existing build and updater. `Package.swift` builds the same source files as a portable library, rather than copying the parsers or sync logic into a second implementation. Linux uses Apple's Swift Crypto package and the system SQLite library. No notebook migration or file-format change is needed.

## Working shared code

- Task hierarchy, goals, extra metadata, and folder checklist extraction.
- Local file scanning, safe links, and link rebasing.
- Revision-aware recovery writes and persistent SQLite undo.
- Git account lookup through existing CLIs, sync, merge preparation, conflict staging, and live checkpoint storage.
- JavaScript editor, task UI, CRDT model, and self-hosted memory-only relay.

`swift test` runs real temporary-repository sync tests, edits arriving during sync, unsafe link rejection, task metadata preservation, crash recovery, and undo across reopening. `node Tests/task-import-contract.mjs` compares the native and JavaScript task readers on the same generated corpus. Editor and Relay keep their own test suites.

## Desktop release requirements still open

| Area | Required before release |
| --- | --- |
| Desktop shell | Notebook sidebar, folders, ordering, favorites, archives, search, shortcuts and file dialogs; keyboard and accessibility testing |
| Editor bridge | The existing editor hosted in an isolated local web view, safe resource loading, images/attachments and OS integration |
| Tasks | Existing list/board/detail UI, goals, labels, progress and folder checklist UI, backed by the shared file services |
| Settings | All Mac preference sections and consistent appearance, typography and labels |
| Git | Existing CLI identities, background sync and the complete in-app conflict review experience |
| Collaboration | Native relay transport, local checkpoint persistence, cross-platform multi-person edits and named live cursors |
| Assistants | Scoped MCP transport, revision checks, activity indicators and assistant configuration |
| Data safety | File watching, chunked writes, concurrent external edits, recovery, undo and permissions tested through the Linux UI |
| Distribution | Linux packages, authenticated update channel, backup/rollback and upgrade tests preserving notebooks and settings |
| Cross-platform verification | Two Linux clients and Mac/Linux sessions; offline rejoin; Unicode, tables, comments, task moves and concurrent edits |

The shared library checks are not a substitute for these end-to-end checks. Linux packages and publishing remain absent while the desktop port is incomplete. Electron's built-in updater does not support Linux; the eventual Linux distribution must have its own verified package/update integration instead of reusing the Mac updater.
