# Omega relay

A small self-hosted WebSocket service for live notes, task pages, subtasks, and goals. No Omega account. Clients use the GitHub or GitLab CLI login already on their Mac; the relay independently checks repository write access before admitting them.

## Run with HTTPS

Point a domain at your server. Install Docker and Compose, then run from this directory:

```sh
export OMEGA_DOMAIN=notes.example.com
export OMEGA_ALLOWED_REPOS='github:your-team/notes,gitlab:your-group/notes'
docker compose up -d --build
```

Open ports 80 and 443. Caddy obtains and renews the TLS certificate. Keep port 8787 private. The relay has no data volume. Only Caddy stores TLS certificates and its configuration; there is no note content in those volumes. To update, run `docker compose up -d --build`. Use one relay process: active rooms exist only in its memory.

For a service manager without Docker:

```sh
npm ci --omit=dev --ignore-scripts
OMEGA_ALLOWED_REPOS='github:your-team/notes' npm start
```

Put an HTTPS reverse proxy in front of `127.0.0.1:8787`. `/health` reports protocol readiness. `/live` is the WebSocket endpoint. Logs intentionally exclude note content and credentials. Disable core dumps, swap for the relay process, and server snapshots. No content backups are required or produced by the relay.

## Connect Omega

1. Each collaborator clones the same repository and branch in Settings → Git sync.
2. Set this relay's HTTPS address under **Live editing**, then enable it for that notebook.
3. Open the same relative note path. Pastel named cursors and selection highlights show where collaborators are working. **Live** in the document footer shows the connection and the people present.

Only open notes use live editing. Other files, new files, moves, and image attachments travel through Git sync. Pause live editing before Git sync; after syncing, reopening a note imports file changes into its stored shared state. A first-time join with different contents offers a local recovery copy before adopting the shared version. The app's recovery folder is available from the live settings card.

Repository host support is currently github.com and gitlab.com. The relay's allowlist uses `github:owner/repository` or `gitlab:group/subgroup/repository`. A trailing `/*` permits repositories below that owner/group. Add team repositories explicitly when needed. Each participant must still have write access—being in the allowlist alone does not grant admission.

## Data and trust

- The native client obtains the credential through `gh auth git-credential` or `glab auth git-credential`. Credentials never enter the editor JavaScript, disk settings, or URLs.
- **Use a relay you trust.** It briefly receives the credential over TLS, calls only the fixed GitHub/GitLab API origins, and discards it. It can read note contents; this is not end-to-end encryption. Deploy your own relay for sensitive repositories.
- Access is checked on every connection. Sessions expire after five minutes and reconnect with a fresh check, bounding access revocation delay. Read-only, archived, disallowed, and unauthenticated repositories are rejected.
- Room identity uses provider + repository ID + branch + note path. Renames create a new room; Git carries file moves. A room is forgotten when its last client disconnects, or when the relay restarts. The next client supplies its saved state; returning clients merge from the same shared baseline. An unrelated baseline requires explicit adoption with a local recovery copy, so independently seeded documents cannot silently duplicate or overwrite text.
- Yjs updates converge under concurrent/offline edits. Rich notes use Tiptap's collaboration binding. Extended Markdown uses a shared text field. Tasks use individual shared text fields, label/goal sets, and independent properties; simultaneous changes to the same scalar property resolve deterministically. Undo during a live session affects that author's changes. The normal Markdown recovery/history remains on disk; collaborative undo stacks themselves restart with the session.
- Presence uses Yjs Awareness, separate from the document: no cursor, selection, or presence identity is included in saved Markdown or CRDT checkpoints. The relay replaces claimed names/colors with its authenticated identity and palette, prevents a connection from impersonating another cursor, isolates presence by room, and removes it on disconnect. Task descriptions currently show a named field indicator; visual/source notes and task titles have precise carets.
- Before publishing an edit, Omega saves a local Markdown recovery checkpoint and writes shared state into `.omega/live/<note-path-sha256>.json` inside the Git notebook. Git Sync commits this state alongside Markdown and attachments. A relay acknowledgement means only that a change was forwarded in memory, not saved remotely. Closing a disconnected editor keeps its local updates for the next join. Git push remains an explicit action; unpushed work is on that Mac only.
- Limits: 4 MiB CRDT state per note, 100 active rooms, 100 simultaneous sockets, bounded message and connection rates. Yjs tombstones count toward the state limit. There are no stored rooms, note databases, server histories, or note backups. Durable data stays in local files and Git. Concurrent offline Git edits can conflict; sync preserves both commits and leaves the working files untouched for resolution. Keep local/Git backups for protection against loss of a Mac.
- Source/visual format changes require pausing live editing. Assistants can edit through the existing revision-checked MCP interface; those edits propagate into an active live note.

## Validation

```sh
npm test
```

Tests use synthetic repositories and credentials. They cover GitHub and GitLab write permissions, allowlists, traversal, rejected authentication, room isolation, simultaneous edits, offline merges, relay restarts, and absence of any saved server data. The editor suite and `Tests/WebLiveCheck.swift` cover rich-text, tasks, local undo, assistants, and actual macOS WebKit clients.

`Tests/WebPresenceCheck.swift` runs three actual macOS WebKit editors over the WebSocket transport. It verifies exact selected text, two named remote cursors, cursor movement after a peer inserts text, unchanged Markdown/checkpoints for cursor-only movement, disconnect cleanup, source selections, and task field presence. By default it starts `Tests/PresenceRelay.mjs` on loopback with synthetic identities (test-only, never deployed). Set `OMEGA_NODE` to the Node executable when needed. `OMEGA_PRESENCE_PUBLIC=1` instead uses the existing GitHub CLI login against omega.naridon.com and a unique synthetic path in MHASK/Omega; it does not create or push a Git file. This is a three-client test on one Mac, not a test on three physical Macs.
