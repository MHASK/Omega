# Omega

A calm, local Markdown notes and tasks app for macOS. No account, no cloud workspace, no built-in AI.

**macOS 14 or later · Apple silicon · Apache 2.0**

[Download the latest release](https://github.com/MHASK/Omega/releases/latest)

## A small place for your work

- Edit ordinary Markdown files in your own folders. Tables, images, math, slash commands, page links, and a selection toolbar.
- Organize notebooks with drag-and-drop ordering, folders, favorites, and archives.
- Find notes with ⌘K, then jump to the matching passage.
- Simple task lists and boards, nested subtasks, descriptions, due dates, labels, and linked goals.
- Manage task statuses and shared pastel labels in Settings (⌘,).
- Local recovery checkpoints, atomic file saves, persistent undo, and update backups.
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

Tests use temporary notes and isolated preferences. GitHub Actions runs editor and native checks on pushes and pull requests.

## Publish a release

The maintainer publishes from a Mac with the official Developer ID certificate. Signing credentials stay in Keychain, not in GitHub or the repository.

1. Build editor resources and run the checks above.
2. Run `./release.sh 1.1.6 116 /absolute/release/path` with a higher version and build number. Set `FOLIO_SIGN_IDENTITY` to the signing identity if needed. To notarize, set `FOLIO_NOTARY_PROFILE` to an existing Keychain profile before running it.
3. Review and commit the version changes, then push `main`.
4. Run `./publish.sh /absolute/release/path /absolute/release-notes.md`.

The script validates the signed app and its manifest, uploads the archive, checksum and `Omega-update.json` as a draft GitHub release, then publishes it. Installed copies discover it automatically. Build checks never receive signing keys or publish unsigned updates.

Forks should use their own repository, app identity and signing requirement before distributing their own update channel.

## Compatibility

Keep `local.folio.notes`, `FolioDataFormatVersion`, the `Folio` executable, Markdown markers, stable task/goal IDs, `folio://` links and preferences keys intact for the official app. These preserve notes, undo history, permissions and existing MCP setups. Never rename user notebooks as part of a product-name change.

Shared label colors are stored in `Settings/labels.json` under the app data directory. Rename/remove operations cover open notebooks, including archived task pages, and keep recoverable previous versions. Closed notebooks are not modified.

## License

Original code: [Apache License 2.0](LICENSE). Third-party components keep the licenses listed in [NOTICE](NOTICE) and the bundled resource notices.
