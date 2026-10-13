import Foundation
import AppKit
@MainActor final class Notebook {
    var roots: [URL] = []
    var reading = false
    func afterSync(_ work: () -> Void) { work() }
    func save() -> Bool { true }
    func showError(_ error: Error) { fatalError(error.localizedDescription) }
}
@main struct UpdateCheck {
    @MainActor static func main() async throws {
        let fm = FileManager.default, app = URL(fileURLWithPath: CommandLine.arguments[1])
        let folder = fm.temporaryDirectory.appendingPathComponent("Folio-Update-Check-" + UUID().uuidString)
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: folder) }
        let build = Int(try FolioUpdates.info(app)["CFBundleVersion"] as! String)!
        try FolioUpdates.verify(app, newerThan: build - 1)
        do { try FolioUpdates.verify(app, newerThan: build); fatalError("Downgrade accepted") } catch {}
        let broken = folder.appendingPathComponent("Folio.app")
        try fm.copyItem(at: app, to: broken)
        try Data("modified".utf8).write(to: broken.appendingPathComponent("Contents/Resources/editor.css"))
        do { try FolioUpdates.verify(broken); fatalError("Tampered update accepted") } catch {}
        let data = folder.appendingPathComponent("App Data"), backup = folder.appendingPathComponent("Backup")
        try fm.createDirectory(at: data.appendingPathComponent("History"), withIntermediateDirectories: true)
        try Data("saved history".utf8).write(to: data.appendingPathComponent("History/undo.sqlite"))
        try fm.createSymbolicLink(at: data.appendingPathComponent("ignored-link"), withDestinationURL: app)
        try FolioUpdates.copyRegularTree(data, to: backup)
        let preserved = try String(contentsOf: backup.appendingPathComponent("History/undo.sqlite"), encoding: .utf8)
        precondition(preserved == "saved history" && !fm.fileExists(atPath: backup.appendingPathComponent("ignored-link").path))
        let old = folder.appendingPathComponent("Old.app"), new = folder.appendingPathComponent("New.app")
        try fm.createDirectory(at: old, withIntermediateDirectories: true); try fm.createDirectory(at: new, withIntermediateDirectories: true)
        try Data("old".utf8).write(to: old.appendingPathComponent("version")); try Data("new".utf8).write(to: new.appendingPathComponent("version"))
        let beforeSwap = try fm.attributesOfItem(atPath: new.appendingPathComponent("version").path)[.systemFileNumber] as! NSNumber
        try FolioUpdates.swapApplications(old, new)
        let next = try String(contentsOf: old.appendingPathComponent("version"), encoding: .utf8)
        let previous = try String(contentsOf: new.appendingPathComponent("version"), encoding: .utf8)
        let afterSwap = try fm.attributesOfItem(atPath: old.appendingPathComponent("version").path)[.systemFileNumber] as! NSNumber
        precondition(next == "new" && previous == "old" && beforeSwap == afterSwap)
        // A running executable remains discoverable after installation. Losing
        // this path makes macOS privacy checks reject otherwise-readable notes.
        let executable = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath().path
        precondition(FolioUpdates.executablePath(getpid()) == executable)
        print("PASS: atomic bundle swap preserves executable inode and process path lookup")
        let version = try FolioUpdates.info(app)["CFBundleShortVersionString"] as! String
        let manifest = OmegaUpdateManifest(schema: 1, version: version, build: build, architecture: "arm64", minimumSystemVersion: "14.0", archive: "https://github.com/MHASK/Omega/releases/download/v\(version)/Omega-\(version).zip", sha256: String(repeating: "a", count: 64), size: 3000)
        _ = try manifest.validate(repository: "MHASK/Omega")
        do { _ = try manifest.validate(repository: "Other/Repo"); fatalError("Wrong release origin accepted") } catch {}
        try OmegaReleaseFeed.validateEntries("Omega.app/\nOmega.app/Contents/file\n", details: "drwxr-xr-x 0 501 20 0 Oct 12 20:00 Omega.app/\n-rwxr-xr-x 0 501 20 23 Oct 12 20:00 Omega.app/Contents/file\n")
        for path in ["../outside", "Omega.app/../outside", "/Omega.app/file", "Omega.app/Contents/../../outside"] {
            do { try OmegaReleaseFeed.validateEntries(path, details: "-rwxr-xr-x 0 501 20 23 Oct 12 20:00 file"); fatalError("Unsafe archive path accepted") } catch {}
        }
        do { try OmegaReleaseFeed.validateEntries("Omega.app/Contents/link", details: "lrwxr-xr-x 0 501 20 23 Oct 12 20:00 file"); fatalError("Symlink accepted") } catch {}
        do { try OmegaReleaseFeed.validateEntries("Omega.app/Contents/file", details: "-rwxr-xr-x 0 501 20 900000000 Oct 12 20:00 file"); fatalError("Oversized archive accepted") } catch {}
        let archive = app.deletingLastPathComponent().appendingPathComponent("Omega-\(version).zip")
        if fm.fileExists(atPath: archive.path) {
            let expanded = folder.appendingPathComponent("Expanded")
            try fm.createDirectory(at: expanded, withIntermediateDirectories: true)
            let extracted = try OmegaReleaseFeed.unpack(archive, in: expanded)
            try FolioUpdates.verify(extracted, newerThan: build - 1)
            print("PASS: packaged archive extracts and retains its release signature")
        }
        if CommandLine.arguments.contains("--live-feed") {
            let session = URLSession(configuration: .ephemeral)
            let release = try await OmegaReleaseFeed.latest(session: session)
            precondition(release.build == build && release.version == version)
            let candidate = try await OmegaReleaseFeed.download(release, session: session, currentBuild: build - 1)
            try FolioUpdates.verify(candidate, newerThan: build - 1)
            try fm.removeItem(at: candidate.deletingLastPathComponent())
            print("PASS: live GitHub release discovery, checksum, download, extraction and signed app verification")
        }
        print("PASS: update manifest origin, archive traversal/symlink/size rejection")
        print("PASS: release signature, downgrade/tamper rejection, history backup, symlink exclusion and atomic application replacement")
    }
}
