# Omega

A calm, local Markdown notes and tasks app for macOS. No account, no cloud workspace, no built-in AI.

**macOS 14 or later · Apple silicon · Apache 2.0**

[Download the latest release](https://github.com/MHASK/Omega/releases/latest)

## A small place for your work

- Edit ordinary Markdown files in your own folders. Tables, images, math, slash commands, page links, and a selection toolbar.
- Organize notebooks with drag-and-drop ordering, folders, favorites, and archives.
- Find notes with ⌘K, then jump to the matching passage. Open Archive from the icon beside ⌘K in the sidebar footer.
- Simple task lists and boards, nested subtasks, descriptions, due dates, labels, and linked goals.
- Manage task statuses and shared pastel labels in Settings (⌘,).
- Local recovery checkpoints, atomic file saves, persistent undo, and update backups.
- Optional Git notebooks with existing GitHub/GitLab CLI login.
- Optional local MCP access for tools such as Claude Code and Codex.

## Install and update

Unzip the release and move **Omega.app** to Applications. The current distribution is Developer ID signed. Releases are not notarized unless their release notes say so; macOS may require first-open approval in Privacy & Security.

Omega checks GitHub releases on launch and every six hours, downloads newer versions, and shows a small dot on Settings when an update is ready. Choose **Settings → About Omega → Restart to update**. You can also use **Omega → Check for Updates**. Automatic checks and downloads can be turned off in Settings.

Every download is checked against its SHA-256 checksum, then verified against the application's bundle identity and Developer ID signing team. Omega saves your current work, backs up notes, preferences, undo/recovery data and the old app, and replaces the application. It does not move your notebooks or change their format. Downgrades and incompatible or tampered apps are rejected. A manual “Install Update from File” fallback is available.

Your notes live in the folders you choose. App data remains in `~/Library/Application Support/Folio`; update backups are in `~/Library/Application Support/Folio Updates`. These historical names preserve existing installations. Local recovery protects against app crashes, but an independent backup is still needed for disk loss.

## Connect a local assistant

Enable **Settings → Assistants → Allow assistant access**, then copy the MCP configuration into your client. For Claude Code:

```sh
claude mcp add --transport stdio --scope user folio -- /Applications/Omega.app/Contents/MacOS/Folio --mcp
```

Restart/reconnect the client after updating Omega. The service supports notes, folders, task pages, nested tasks, goals and goal links. Access is limited to open notebooks; writes use revision checks and saved history. Both you and an assistant can edit, with conflicting writes rejected instead of silently overwriting your work. No notes are sent to GitHub by the updater. A connected assistant handles note content according to that client's settings.

## Git notebooks

Open **Settings → Git sync**. Choose GitHub or GitLab, then **Open Git folder** for an existing repository or enter its HTTPS URL and choose **Clone repository**. The repository becomes a normal notebook in the sidebar. Repositories must have an `origin` HTTPS remote; use the repository's top folder. Nested GitLab groups and self-hosted hosts are supported by the selected CLI's existing host login.

Omega calls the installed `gh` or `glab` credential helper for that host. It does not create an Omega account, copy tokens into its settings, or change your global Git configuration. Sign in once with `gh auth login` or `glab auth login` if needed, and configure your usual Git commit name/email. A login supplied only through a terminal environment variable is available only to processes launched with that environment; use the CLI's persistent login for apps opened from Finder.

**Sync** saves the current note, commits changed Markdown/text notes and image/PDF attachments, merges incoming changes, then pushes. Existing repository history is shared too, so use a repository intended for these notes. Hidden files and unrelated new files are not automatically committed. Preferences, archive/favorite flags, undo history, and shared label colors remain local to each Mac. Nothing is uploaded until you choose Sync; ordinary notebooks remain local.

Incoming merges are tested in a temporary worktree. Overlapping edits stop with your live files intact and local edits committed. Resolve that conflict with Git, then sync again. There are no force pushes or resets of working files. Staged changes or an unfinished merge/rebase block sync. File changes arriving during synchronization are preserved and may require another sync. A local Git backup reference is kept before accepting incoming changes.

Git sync saves files and their history. Optional live editing shares concurrent changes through a memory-only relay; it requires a connected Git notebook and repository write access. The local assistant integration continues to use revision checks to protect concurrent writes.

## Build

Install Xcode Command Line Tools and Node.js 22 or later:

```sh
npm ci --prefix Editor
npm test --prefix Editor
npm run build --prefix Editor
./build.sh /absolute/path/Omega.app
```

The native app is SwiftUI/AppKit with a local Tiptap editor. Editor resources and dependency notices are bundled into the app; no CDN is used. Build output is arm64, targeting macOS 14. Development builds are ad-hoc signed and are not accepted by the official updater.

Run native checks on an Apple silicon Mac:

```sh
/path/Omega.app/Contents/MacOS/Folio --self-test
/path/Omega.app/Contents/MacOS/Folio --mcp-test
/path/Omega.app/Contents/MacOS/Folio --undo-test
```

Run Git synchronization checks with two temporary repositories:

```sh
xcrun swiftc GitSync.swift Tests/GitSyncCheck.swift -o /tmp/Omega-Git-Check
/tmp/Omega-Git-Check
```

Tests use temporary notes and isolated preferences. GitHub Actions runs editor and native checks on pushes and pull requests.

## Publish a release

The maintainer publishes from a Mac with the official Developer ID certificate. Signing credentials stay in Keychain, not in GitHub or the repository.

1. Build editor resources and run the checks above.
2. Run `./release.sh 1.2.0 120 /absolute/release/path` with a higher version and build number. Set `FOLIO_SIGN_IDENTITY` to the signing identity if needed. To notarize, set `FOLIO_NOTARY_PROFILE` to an existing Keychain profile before running it.
3. Review and commit the version changes, then push `main`.
4. Run `./publish.sh /absolute/release/path /absolute/release-notes.md`.

The script validates the signed app and its manifest, uploads the archive, checksum and `Omega-update.json` as a draft GitHub release, then publishes it. Installed copies discover it automatically. Build checks never receive signing keys or publish unsigned updates.

Forks should use their own repository, app identity and signing requirement before distributing their own update channel.

## Compatibility

Keep `local.folio.notes`, `FolioDataFormatVersion`, the `Folio` executable, Markdown markers, stable task/goal IDs, `folio://` links and preferences keys intact for the official app. These preserve notes, undo history, permissions and existing MCP setups. Never rename user notebooks as part of a product-name change.

Shared label colors are stored in `Settings/labels.json` under the app data directory. Rename/remove operations cover open notebooks, including archived task pages, and keep recoverable previous versions. Closed notebooks are not modified.

## License

Original code: [Apache License 2.0](LICENSE). Third-party components keep the licenses listed in [NOTICE](NOTICE) and the bundled resource notices.

### Live collaboration

Settings → Git sync now includes **Live editing**. Connect the same Git repository and branch on each Mac, set your trusted relay address, and enable it. Open the same note to write together; the footer shows Live and the people present. Notes, task fields, subtasks, and linked goals merge through Yjs. Local recovery remains active while offline.

The hosted relay for this installation is `https://omega.naridon.com`. It permits repositories under `MHASK` on GitHub and `ashiqwayanad007` on GitLab, with each participant's write permission checked separately. Other deployments can choose their own allowlist. No note is uploaded simply by installing the app.

[Relay setup and trust model](Relay/README.md) includes Docker Compose, HTTPS, access checks, and the zero-persistence model. Git carries notes, attachments, and the shared editing checkpoints under `.omega/live/`. Live editing shares open document contents; the relay never writes them to disk and forgets a room when its last participant leaves. Pause live editing before a Git sync. Live undo is author-local within the session; durable Markdown history stays local.
