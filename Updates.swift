import AppKit
import Foundation
import Security
import UniformTypeIdentifiers

// Updates replace only the signed application. Notes, preferences and recovery
// live outside it. The same team and bundle identity are required on every build.
enum FolioUpdates {
    static let bundleID = "local.folio.notes"
    static let teamID = "A5S8X4RCAS"
    static var backupRoot: URL { FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Folio Updates") }
    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }
    struct Plan: Codable {
        let staged: URL
        let installed: URL
        let backup: URL
        let pid: Int32
        let preferences: Data
        let notebooks: [URL]
    }
    static func info(_ app: URL) throws -> [String: Any] {
        let data = try Data(contentsOf: app.appendingPathComponent("Contents/Info.plist"))
        guard let value = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else { throw Failure(message: "This isn't a Omega application.") }
        return value
    }
    static func verify(_ app: URL, newerThan current: Int? = nil) throws {
        let fm = FileManager.default
        guard app.pathExtension == "app", app.resolvingSymlinksInPath().path == app.standardizedFileURL.path else { throw Failure(message: "Choose the Omega.app application itself.") }
        let values = try info(app)
        guard values["CFBundleIdentifier"] as? String == bundleID,
              let build = Int(values["CFBundleVersion"] as? String ?? ""), build > 0,
              values["FolioDataFormatVersion"] as? Int == 1 else { throw Failure(message: "This build isn't compatible with this Omega installation.") }
        if let current, build <= current { throw Failure(message: "Choose a newer version of Omega. Your current app hasn't changed.") }
        let minimum = values["LSMinimumSystemVersion"] as? String ?? "14.0"
        let os = ProcessInfo.processInfo.operatingSystemVersion
        guard "\(os.majorVersion).\(os.minorVersion).\(os.patchVersion)".compare(minimum, options: .numeric) != .orderedAscending else { throw Failure(message: "This update needs macOS \(minimum) or later.") }
        guard fm.isExecutableFile(atPath: app.appendingPathComponent("Contents/MacOS/Folio").path) else { throw Failure(message: "The Omega executable is missing.") }
        var code: SecStaticCode?, requirement: SecRequirement?
        let expression = "anchor apple generic and identifier \"\(bundleID)\" and certificate leaf[subject.OU] = \"\(teamID)\""
        guard SecStaticCodeCreateWithPath(app as CFURL, [], &code) == errSecSuccess,
              SecRequirementCreateWithString(expression as CFString, [], &requirement) == errSecSuccess,
              let code, let requirement,
              SecStaticCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSStrictValidate | kSecCSCheckNestedCode), requirement) == errSecSuccess else { throw Failure(message: "Omega couldn't verify this update's signature. Nothing was replaced.") }
    }
    @MainActor static func choose(notebook: Notebook, willQuit: @escaping () -> Void) {
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.application]; panel.canChooseDirectories = false; panel.canChooseFiles = true
        panel.title = "Install an Omega update"; panel.message = "Choose a newer, signed Omega.app. Your notes stay in their current folders."; panel.prompt = "Continue"
        guard panel.runModal() == .OK, let candidate = panel.url else { return }
        install(candidate, notebook: notebook, willQuit: willQuit)
    }
    @MainActor static func install(_ candidate: URL, notebook: Notebook, willQuit: @escaping () -> Void) {
        notebook.afterSync {
            do {
                let current = Bundle.main.bundleURL.standardizedFileURL
                let build = Int(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0") ?? 0
                try verify(candidate, newerThan: build)
                guard current != candidate, FileManager.default.isWritableFile(atPath: current.deletingLastPathComponent().path) else { throw Failure(message: "Move Omega into your Applications folder before installing an update.") }
                let version = try info(candidate)["CFBundleShortVersionString"] as? String ?? ""
                let alert = NSAlert(); alert.messageText = "Install Omega \(version)?"
                alert.informativeText = "Omega will save your work and restart. The current app, notes, settings and recovery history will be backed up first."
                alert.addButton(withTitle: "Install & Restart"); alert.addButton(withTitle: "Cancel")
                guard alert.runModal() == .alertFirstButtonReturn else { return }
                guard notebook.save() else { return }
                let fm = FileManager.default, token = UUID().uuidString
                let staged = current.deletingLastPathComponent().appendingPathComponent(".Folio-update-" + token + ".app")
                do {
                    try fm.copyItem(at: candidate, to: staged); try verify(staged, newerThan: build)
                    let backup = backupRoot.appendingPathComponent(ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-") + "-" + token.prefix(6))
                    try fm.createDirectory(at: backup, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                    let preferences = try PropertyListSerialization.data(fromPropertyList: UserDefaults.standard.persistentDomain(forName: bundleID) ?? [:], format: .binary, options: 0)
                    let plan = Plan(staged: staged, installed: current, backup: backup, pid: getpid(), preferences: preferences, notebooks: notebook.roots)
                    let planURL = backup.appendingPathComponent("update.json")
                    try JSONEncoder().encode(plan).write(to: planURL, options: .atomic)
                    let helperApp = backup.appendingPathComponent("Update Helper.app")
                    try fm.copyItem(at: current, to: helperApp)
                    let process = Process(); process.executableURL = helperApp.appendingPathComponent("Contents/MacOS/Folio"); process.arguments = ["--finish-update", planURL.path]; try process.run()
                    notebook.reading = true; willQuit(); NSApp.terminate(nil)
                } catch { try? fm.removeItem(at: staged); throw error }
            } catch { notebook.showError(error) }
        }
    }
    static func copyRegularTree(_ source: URL, to destination: URL) throws {
        let fm = FileManager.default
        let source = source.resolvingSymlinksInPath()
        guard fm.fileExists(atPath: source.path) else { return }
        guard let files = fm.enumerator(at: source, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey], options: []) else { throw Failure(message: "Couldn't read the existing recovery history.") }
        for case let file as URL in files {
            let values = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            if values.isSymbolicLink == true { continue }
            guard values.isRegularFile == true else { continue }
            let canonical = file.resolvingSymlinksInPath()
            guard canonical.path.hasPrefix(source.path + "/") else { throw Failure(message: "A backup path changed while copying.") }
            let target = destination.appendingPathComponent(String(canonical.path.dropFirst(source.path.count + 1)))
            try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try fm.copyItem(at: file, to: target)
        }
    }
    @MainActor static func finish(planURL: URL) -> Int32 {
        let fm = FileManager.default
        var plan: Plan?
        var replaced = false
        do {
            let value = try JSONDecoder().decode(Plan.self, from: Data(contentsOf: planURL)); plan = value
            guard ["Folio.app", "Omega.app"].contains(value.installed.lastPathComponent), value.staged.lastPathComponent.hasPrefix(".Folio-update-"), value.staged.deletingLastPathComponent() == value.installed.deletingLastPathComponent(), value.backup.path.hasPrefix(backupRoot.path + "/"), value.pid > 1 else { throw Failure(message: "Invalid update plan.") }
            for _ in 0..<240 { if kill(value.pid, 0) != 0 { break }; Thread.sleep(forTimeInterval: 0.25) }
            guard kill(value.pid, 0) != 0 else { throw Failure(message: "Omega is still running. Quit it and try the update again.") }
            try verify(value.staged)
            let savedApp = value.backup.appendingPathComponent("Folio.app")
            try value.preferences.write(to: value.backup.appendingPathComponent("Preferences.plist"), options: .atomic)
            let support = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Folio")
            try copyRegularTree(support, to: value.backup.appendingPathComponent("App Data"))
            // Keep note snapshots separate from their originals, with their paths.
            let notes = value.backup.appendingPathComponent("Notes")
            try fm.createDirectory(at: notes, withIntermediateDirectories: true)
            var manifest: [[String: String]] = [], seen = Set<String>()
            for root in value.notebooks {
                for entry in NoteFiles.flatten(try NoteFiles.scan(root)) where !entry.isFolder && seen.insert(entry.url.path).inserted {
                    let name = UUID().uuidString + "." + entry.url.pathExtension
                    try fm.copyItem(at: entry.url, to: notes.appendingPathComponent(name))
                    manifest.append(["original": entry.url.path, "copy": name])
                }
            }
            try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys]).write(to: notes.appendingPathComponent("Paths.json"))
            try fm.copyItem(at: value.installed, to: savedApp)
            // Atomic same-volume replacement: on failure the original stays usable.
            _ = try fm.replaceItemAt(value.installed, withItemAt: value.staged, backupItemName: ".Folio-previous-" + UUID().uuidString + ".app", options: [])
            replaced = true
            try verify(value.installed)
            let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/bin/open"); process.arguments = ["-n", value.installed.path]; try process.run(); process.waitUntilExit()
            guard process.terminationStatus == 0 else { throw Failure(message: "The updated app couldn't be opened.") }
            try? fm.removeItem(at: planURL)
            return 0
        } catch {
            if let plan {
                if replaced {
                    let restored = plan.installed.deletingLastPathComponent().appendingPathComponent(".Folio-restore-" + UUID().uuidString + ".app")
                    do { try fm.copyItem(at: plan.backup.appendingPathComponent("Folio.app"), to: restored); _ = try fm.replaceItemAt(plan.installed, withItemAt: restored) } catch { /* The backup remains available. */ }
                }
                try? fm.removeItem(at: plan.staged)
                let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/bin/open"); process.arguments = [plan.installed.path]; try? process.run()
            }
            let app = NSApplication.shared; app.setActivationPolicy(.accessory)
            let alert = NSAlert(); alert.messageText = "The update wasn't installed"; alert.informativeText = error.localizedDescription + "\nYour notes and the previous app are preserved."; alert.runModal()
            return 1
        }
    }
}
