import Foundation
import Darwin
import CryptoKit

enum GitDigest { static func of(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() } }

struct GitFailure: LocalizedError {
    let message: String
    var errorDescription: String? { message }
    init(_ message: String) { self.message = message }
}

enum GitProvider: String, Codable, CaseIterable, Identifiable {
    case github = "GitHub", gitlab = "GitLab"
    var id: String { rawValue }
    var cli: String { self == .github ? "gh" : "glab" }
    var defaultHost: String { self == .github ? "github.com" : "gitlab.com" }
}
struct GitNotebook: Codable, Identifiable, Equatable {
    let path: String
    let provider: GitProvider
    var automatic: Bool? = nil
    var autoSync: Bool { automatic ?? true }
    var id: String { path }
    var url: URL { URL(fileURLWithPath: path) }
}
struct GitRemote: Equatable {
    let url: String
    let host: String
    let project: String
    init(_ value: String) throws {
        guard let parsed = URLComponents(string: value), parsed.scheme == "https",
              let host = parsed.host, !host.isEmpty, parsed.user == nil, parsed.password == nil,
              parsed.query == nil, parsed.fragment == nil, parsed.port == nil,
              !value.contains(where: { $0.isWhitespace || $0.isNewline }) else {
            throw GitFailure("Use a repository’s HTTPS URL, without a password or token.")
        }
        var path = parsed.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if path.hasSuffix(".git") { path = String(path.dropLast(4)) }
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count >= 2, parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." && $0.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || "-_.".contains($0)) }) }) else {
            throw GitFailure("Use the full repository URL, including its owner and name.")
        }
        self.host = host.lowercased(); project = path; url = "https://\(self.host)/\(path).git"
    }
}
struct GitSnapshot {
    let branch: String
    let remote: GitRemote
    let changedFiles: Int
}

// Git works on the same local Markdown files as the editor. Tokens are supplied
// directly by the installed CLI's credential helper, never read or saved here.
struct GitRunner {
    struct Output { let status: Int32; let data: Data; var text: String { String(decoding: data, as: UTF8.self) } }
    var executable = URL(fileURLWithPath: "/usr/bin/git")
    var timeout: TimeInterval = 90
    static func cli(_ name: String) -> URL? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let directories = ["/opt/homebrew/bin", "/usr/local/bin", home + "/.local/bin", "/usr/bin"] + (ProcessInfo.processInfo.environment["PATH"] ?? "").components(separatedBy: ":")
        return directories.map { URL(fileURLWithPath: $0).appendingPathComponent(name) }.first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }
    func run(_ args: [String], in directory: URL, environment: [String: String] = [:], allowFailure: Bool = false, input: String? = nil) throws -> Output {
        let process = Process(), pipe = Pipe()
        process.executableURL = executable; process.arguments = args; process.currentDirectoryURL = directory
        var env = ProcessInfo.processInfo.environment
        // Do not inherit a terminal's alternate index/worktree or injected Git options.
        for key in env.keys where key.hasPrefix("GIT_") { env.removeValue(forKey: key) }
        env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:" + (env["PATH"] ?? "")
        env["GIT_TERMINAL_PROMPT"] = "0"; env["GCM_INTERACTIVE"] = "never"; env["GH_PROMPT_DISABLED"] = "1"; env["GLAB_CHECK_UPDATE"] = "false"
        env["LC_ALL"] = "C"; env.merge(environment, uniquingKeysWith: { _, new in new })
        let stdin = input == nil ? nil : Pipe()
        process.environment = env; process.standardInput = stdin ?? FileHandle.nullDevice
        process.standardOutput = pipe; process.standardError = pipe
        let timeoutWork = DispatchWorkItem { if process.isRunning { process.terminate() } }
        try process.run()
        if let input, let stdin { stdin.fileHandleForWriting.write(Data(input.utf8)); try? stdin.fileHandleForWriting.close() }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: timeoutWork)
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit(); timeoutWork.cancel()
        let result = Output(status: process.terminationStatus, data: data)
        // Never surface raw CLI output: it can include credentials from a user's remote/config.
        if result.status != 0 && !allowFailure { throw GitFailure("Git couldn’t finish this step. Your local files are safe. Check the repository and your CLI connection, then try again.") }
        return result
    }
    func git(_ args: [String], at root: URL, credentials: [String] = [], allowFailure: Bool = false) throws -> Output {
        try run(["-c", "core.hooksPath=/dev/null", "-c", "commit.gpgSign=false", "-c", "submodule.recurse=false", "-c", "core.quotePath=false", "-c", "http.lowSpeedLimit=1000", "-c", "http.lowSpeedTime=30"] + credentials + args, in: root, allowFailure: allowFailure)
    }
    static func helperArguments(provider: GitProvider, remote: GitRemote) throws -> [String] {
        guard let cli = cli(provider.cli) else { throw GitFailure("Install \(provider.cli) and sign in there once. Omega will use that existing login.") }
        let quoted = "'" + cli.path.replacingOccurrences(of: "'", with: "'\\''") + "'"
        return ["-c", "credential.helper=", "-c", "credential.https://\(remote.host).helper=!\(quoted) auth git-credential", "-c", "credential.interactive=false"]
    }
    func account(_ provider: GitProvider, host: String? = nil) throws -> String {
        guard let cli = Self.cli(provider.cli) else { throw GitFailure("\(provider.cli) isn’t installed") }
        let runner = GitRunner(executable: cli, timeout: 15)
        let result = try runner.run(["api", "user", "--hostname", host ?? provider.defaultHost], in: FileManager.default.temporaryDirectory)
        guard let data = result.text.data(using: .utf8), let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let login = json[provider == .github ? "login" : "username"] as? String else { throw GitFailure("Sign in with \(provider.cli)") }
        return login
    }
    func inspect(_ root: URL) throws -> GitSnapshot {
        let top = try git(["rev-parse", "--show-toplevel"], at: root).text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard URL(fileURLWithPath: top).resolvingSymlinksInPath().path == root.resolvingSymlinksInPath().path else { throw GitFailure("Choose the repository’s top folder so its scope is clear.") }
        let branch = try git(["symbolic-ref", "--quiet", "--short", "HEAD"], at: root, allowFailure: true)
        guard branch.status == 0 else { throw GitFailure("Switch this repository to a branch before syncing.") }
        let remote = try GitRemote(git(["config", "--get", "remote.origin.url"], at: root).text.trimmingCharacters(in: .whitespacesAndNewlines))
        let count = try git(["status", "--porcelain=v1", "--untracked-files=all", "-z"], at: root).text.split(separator: "\0").count
        return GitSnapshot(branch: branch.text.trimmingCharacters(in: .whitespacesAndNewlines), remote: remote, changedFiles: count)
    }
    func clone(_ remote: GitRemote, provider: GitProvider, to destination: URL) throws {
        guard !FileManager.default.fileExists(atPath: destination.path) else { throw GitFailure("Choose a new folder for this repository.") }
        let credentials = try Self.helperArguments(provider: provider, remote: remote)
        _ = try git(["clone", "--", remote.url, destination.path], at: destination.deletingLastPathComponent(), credentials: credentials)
    }

    // Markdown/text, attachments, and narrowly scoped shared editing checkpoints are committed.
    // Hidden files, code, secrets, and any unrelated staged work stay out of sync.
    static func isNotePath(_ path: String) -> Bool {
        if path.range(of: "^\\.omega/live/[a-f0-9]{64}\\.json$", options: .regularExpression) != nil { return true }
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        return !parts.isEmpty && parts.allSatisfy { !$0.isEmpty && !$0.hasPrefix(".") } &&
            ["md", "markdown", "txt", "png", "jpg", "jpeg", "gif", "webp", "svg", "heic", "pdf"].contains(URL(fileURLWithPath: path).pathExtension.lowercased())
    }
    func commitNotes(_ root: URL) throws {
        _ = try inspect(root)
        let gitPath = try git(["rev-parse", "--absolute-git-dir"], at: root).text.trimmingCharacters(in: .whitespacesAndNewlines)
        for name in ["MERGE_HEAD", "CHERRY_PICK_HEAD", "REVERT_HEAD", "rebase-merge", "rebase-apply"] {
            if FileManager.default.fileExists(atPath: gitPath + "/" + name) { throw GitFailure("Finish the current merge or rebase in Git before syncing. Omega hasn’t changed your files.") }
        }
        guard try git(["diff", "--cached", "--quiet"], at: root, allowFailure: true).status == 0 else {
            throw GitFailure("There are staged changes in this repository. Commit or unstage them in Git first.")
        }
        let tracked = try git(["ls-files", "-z"], at: root).text.split(separator: "\0").map(String.init)
        let untracked = try git(["ls-files", "--others", "--exclude-standard", "-z"], at: root).text.split(separator: "\0").map(String.init)
        let changed = try git(["diff", "--name-only", "--no-renames", "-z"], at: root).text.split(separator: "\0").map(String.init)
        guard changed.allSatisfy(Self.isNotePath) else { throw GitFailure("This repository has changes outside notes and attachments. Commit those in Git first.") }
        let paths = Set(tracked + untracked).filter(Self.isNotePath).sorted()
        for path in paths {
            let file = root.appendingPathComponent(path)
            if file.resolvingSymlinksInPath().path != root.resolvingSymlinksInPath().appendingPathComponent(path).standardizedFileURL.path { throw GitFailure("Move symbolic links outside this notebook before syncing.") }
        }
        if !paths.isEmpty {
            // Lock the ordinary index while preparing an isolated one. Other Git
            // writers cannot lose staged changes, and failed commits leave it intact.
            let ordinaryIndex = URL(fileURLWithPath: gitPath).appendingPathComponent("index")
            let indexLockURL = ordinaryIndex.appendingPathExtension("lock")
            let indexLock = open(indexLockURL.path, O_CREAT | O_EXCL | O_WRONLY, 0o600)
            guard indexLock >= 0 else { throw GitFailure("Git is busy in this folder. Try syncing again after it finishes.") }
            defer { close(indexLock); try? FileManager.default.removeItem(at: indexLockURL) }
            guard try git(["diff", "--cached", "--quiet"], at: root, allowFailure: true).status == 0 else { throw GitFailure("Staged changes appeared. Finish them in Git before syncing.") }
            let index = URL(fileURLWithPath: gitPath).appendingPathComponent("omega-index-" + UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: index) }
            let env = ["GIT_INDEX_FILE": index.path]
            let base = ["-c", "core.hooksPath=/dev/null", "-c", "commit.gpgSign=false"]
            if try git(["rev-parse", "--verify", "HEAD"], at: root, allowFailure: true).status == 0 { _ = try run(base + ["read-tree", "HEAD"], in: root, environment: env) }
            // Literal pathspecs prevent note filenames from becoming Git wildcard expressions.
            for chunk in stride(from: 0, to: paths.count, by: 100) {
                _ = try run(base + ["--literal-pathspecs", "add", "-A", "--"] + Array(paths[chunk..<min(chunk + 100, paths.count)]), in: root, environment: env)
            }
            if try run(base + ["diff", "--cached", "--quiet"], in: root, environment: env, allowFailure: true).status != 0 {
                _ = try run(base + ["commit", "-m", "Update notes in Omega"], in: root, environment: env)
                // Install the committed index under the held lock; working files stay untouched.
                try Data(contentsOf: index).write(to: indexLockURL)
                let handle = try FileHandle(forWritingTo: indexLockURL); try handle.synchronize(); try handle.close()
                guard rename(indexLockURL.path, ordinaryIndex.path) == 0 else { throw GitFailure("The notes were committed, but Git’s index couldn’t be updated. Your files and commit are safe.") }
            }
        }
    }
    func sync(_ root: URL, credentials: [String]) throws -> String {
        let session = try GitSyncSession(root: root, runner: self)
        defer { session.discard() }
        try session.fetch(credentials: credentials)
        guard try session.conflicts().isEmpty else { throw GitFailure("Both copies changed the same content. Review the copies in Omega.") }
        _ = try session.apply()
        return try session.push(credentials: credentials)
    }
}

// A sync owns a private merge worktree. Network requests never touch an open
// document. Only apply() touches the checkout, under the app's short main-actor
// save transaction; all slower work runs in the background.
struct GitReview: Identifiable {
    let path: String
    let mine: Data?
    let incoming: Data?
    let base: Data?
    let checkpointPath: String?
    var id: String { path }
    var editable: Bool { ["md", "markdown", "txt"].contains(URL(fileURLWithPath: path).pathExtension.lowercased()) && [mine, incoming].compactMap { $0 }.allSatisfy { $0.count < 2_000_000 && String(data: $0, encoding: .utf8) != nil } }
}
struct GitSharedPair {
    let path: String
    let checkpointPath: String
    let mine: LiveCheckpoint
    let incoming: LiveCheckpoint
    let mineText: String
    let incomingText: String
}
struct GitChangedDuringSync: LocalizedError {
    var errorDescription: String? { "New edits are safe. Omega will include them in the next sync." }
}

final class GitSyncSession: @unchecked Sendable {
    struct Record: Codable {
        let branch: String
        let remoteURL: String
        let remoteBranch: String
        var head: String
        var fetched: String?
        var workspace: String?
        var resolved: [String] = []
        var manual: [String] = []
        var reviewDrafts: [String: String]?
        let baseline: [String: String]
    }
    let root: URL
    let runner: GitRunner
    let directory: URL
    var record: Record
    private var lock: Int32 = -1
    private let fm = FileManager.default
    private(set) var applied = false
    var workspace: URL? { record.workspace.map { URL(fileURLWithPath: $0) } }
    var reviewFile: URL { directory.appendingPathComponent("omega-review.json") }
    var branch: String { record.branch }
    var hasIncoming: Bool { workspace != nil }

    init(root input: URL, runner: GitRunner = GitRunner(), restoring: Bool = false) throws {
        let root = input.resolvingSymlinksInPath()
        self.root = root; self.runner = runner
        let info = try runner.inspect(root)
        directory = URL(fileURLWithPath: try runner.git(["rev-parse", "--absolute-git-dir"], at: root).text.trimmingCharacters(in: .whitespacesAndNewlines))
        let upstream = try runner.git(["config", "--get", "branch.\(info.branch).merge"], at: root, allowFailure: true).text.trimmingCharacters(in: .whitespacesAndNewlines)
        let remoteBranch = upstream.isEmpty ? "refs/heads/" + info.branch : upstream
        let remote = try runner.git(["config", "--get", "branch.\(info.branch).remote"], at: root, allowFailure: true).text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard remote.isEmpty || remote == "origin", remoteBranch.hasPrefix("refs/heads/"), try runner.git(["check-ref-format", remoteBranch], at: root, allowFailure: true).status == 0 else { throw GitFailure("Set this branch’s upstream to a regular origin branch before syncing.") }
        record = Record(branch: info.branch, remoteURL: info.remote.url, remoteBranch: remoteBranch, head: "", baseline: [:])
        lock = open(directory.appendingPathComponent("omega-sync.lock").path, O_CREAT | O_RDWR, 0o600)
        guard lock >= 0, flock(lock, LOCK_EX | LOCK_NB) == 0 else { if lock >= 0 { close(lock); lock = -1 }; throw GitFailure("This notebook is already syncing.") }
        do {
            var restored = false
            if restoring, let data = try? Data(contentsOf: reviewFile), let saved = try? JSONDecoder().decode(Record.self, from: data) {
                let safePath = saved.workspace.map { $0.hasPrefix(directory.appendingPathComponent("omega-merge").path + "/") } == true
                if safePath, saved.branch == info.branch, saved.remoteURL == info.remote.url,
                   saved.head == (try? command(["rev-parse", "HEAD"])), let path = saved.workspace, fm.fileExists(atPath: path) {
                    record = saved; restored = true
                } else {
                    if safePath, let path = saved.workspace { _ = try? runner.git(["worktree", "remove", "--force", path], at: root) }
                    try? fm.removeItem(at: reviewFile)
                }
            }
            if !restored {
                try runner.commitNotes(root)
                let head = try command(["rev-parse", "HEAD"])
                record = Record(branch: info.branch, remoteURL: info.remote.url, remoteBranch: remoteBranch, head: head, baseline: try workingSnapshot())
                guard try runner.git(["diff", "--quiet"], at: root, allowFailure: true).status == 0 else { throw GitChangedDuringSync() }
            }
        } catch { releaseLock(); throw error }
    }
    deinit { releaseLock() }
    private func releaseLock() { if lock >= 0 { flock(lock, LOCK_UN); close(lock); lock = -1 } }
    func command(_ args: [String], at folder: URL? = nil) throws -> String { try runner.git(args, at: folder ?? root).text.trimmingCharacters(in: .whitespacesAndNewlines) }
    func paths(_ ref: String) throws -> [String] { try runner.git(["ls-tree", "-r", "--name-only", "-z", ref], at: root).text.split(separator: "\0").map(String.init) }
    func blob(_ ref: String, _ path: String) throws -> Data? {
        let result = try runner.git(["cat-file", "blob", ref + ":" + path], at: root, allowFailure: true)
        return result.status == 0 ? result.data : nil
    }
    private func workingSnapshot() throws -> [String: String] {
        let tracked = try runner.git(["ls-files", "-z"], at: root).text.split(separator: "\0").map(String.init)
        let extra = try runner.git(["ls-files", "--others", "--exclude-standard", "-z"], at: root).text.split(separator: "\0").map(String.init)
        var result: [String: String] = [:]
        for path in Set(tracked + extra).filter(GitRunner.isNotePath) {
            let url = root.appendingPathComponent(path)
            guard url.resolvingSymlinksInPath().path == root.resolvingSymlinksInPath().appendingPathComponent(path).standardizedFileURL.path else { throw GitFailure("Symbolic links cannot be synced as notes.") }
            if fm.fileExists(atPath: url.path) { result[path] = GitDigest.of(try Data(contentsOf: url)) }
        }
        return result
    }
    func validate(except paths: Set<String> = []) throws {
        guard try command(["rev-parse", "HEAD"]) == record.head,
              try command(["symbolic-ref", "--short", "HEAD"]) == record.branch,
              try GitRemote(command(["config", "--get", "remote.origin.url"])).url == record.remoteURL,
              try runner.git(["diff", "--cached", "--quiet"], at: root, allowFailure: true).status == 0 else { throw GitChangedDuringSync() }
        let now = try workingSnapshot()
        guard now.filter({ !paths.contains($0.key) }) == record.baseline.filter({ !paths.contains($0.key) }) else { throw GitChangedDuringSync() }
    }
    func fetch(credentials: [String]) throws {
        let found = try runner.git(["ls-remote", "--heads", "origin", record.remoteBranch], at: root, credentials: credentials).text
        guard !found.isEmpty else { return }
        _ = try runner.git(["fetch", "--no-tags", "origin", record.remoteBranch], at: root, credentials: credentials)
        let fetched = try command(["rev-parse", "FETCH_HEAD"])
        guard try runner.git(["merge-base", "--is-ancestor", fetched, record.head], at: root, allowFailure: true).status != 0 else { return }
        record.fetched = fetched
        let base = try command(["merge-base", record.head, fetched])
        let changed = try runner.git(["diff", "--name-only", "--no-renames", "-z", base, fetched], at: root).text.split(separator: "\0").map(String.init)
        guard changed.allSatisfy(GitRunner.isNotePath) else { throw GitFailure("Incoming changes include files outside notes and attachments. Update this repository in Git first.") }
        // Never check out a remote symbolic link or submodule into the notebook.
        let entries = try runner.git(["ls-tree", "-r", "-z", fetched], at: root).text.split(separator: "\0")
        guard !entries.contains(where: { $0.hasPrefix("120000 ") || $0.hasPrefix("160000 ") }) else { throw GitFailure("Incoming symbolic links or submodules need to be handled in Git.") }
        let parent = directory.appendingPathComponent("omega-merge")
        try fm.createDirectory(at: parent, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let folder = parent.appendingPathComponent(UUID().uuidString)
        _ = try command(["worktree", "add", "--detach", folder.path, record.head])
        record.workspace = folder.path
        _ = try command(["update-ref", "refs/omega/backups/" + folder.lastPathComponent + "-local", record.head])
        _ = try command(["update-ref", "refs/omega/backups/" + folder.lastPathComponent + "-incoming", fetched])
        _ = try runner.git(["merge", "--no-commit", "--no-ff", fetched], at: folder, allowFailure: true)
        // A failed merge must either leave actual conflicts or a valid merge index.
        guard fm.fileExists(atPath: (try command(["rev-parse", "--absolute-git-dir"], at: folder)) + "/MERGE_HEAD") else { throw GitFailure("Git could not prepare the incoming changes. Your notebook is unchanged.") }
    }
    func unresolved() throws -> [String] {
        guard let workspace else { return [] }
        return try runner.git(["diff", "--name-only", "--diff-filter=U", "-z"], at: workspace).text.split(separator: "\0").map(String.init)
    }
    func notePaths() throws -> [String] {
        var all = try Set(paths(record.head) + (record.fetched.map { try paths($0) } ?? []))
        if let fetched = record.fetched { all.formUnion(try paths(command(["merge-base", record.head, fetched]))) }
        return all.filter { GitRunner.isNotePath($0) && !$0.hasPrefix(".omega/") && ["md", "markdown", "txt"].contains(URL(fileURLWithPath: $0).pathExtension.lowercased()) }.sorted()
    }
    func checkpointPath(_ note: String) -> String { ".omega/live/" + GitDigest.of(Data(note.utf8)) + ".json" }
    func sharedPairs() throws -> [GitSharedPair] {
        guard let fetched = record.fetched else { return [] }
        return try notePaths().compactMap { path in
            let cp = checkpointPath(path)
            guard let left = try blob(record.head, cp), let right = try blob(fetched, cp), left != right,
                  let mine = try? JSONDecoder().decode(LiveCheckpoint.self, from: left), let incoming = try? JSONDecoder().decode(LiveCheckpoint.self, from: right),
                  let a = try blob(record.head, path), let b = try blob(fetched, path),
                  let mineText = String(data: a, encoding: .utf8), let incomingText = String(data: b, encoding: .utf8) else { return nil }
            return GitSharedPair(path: path, checkpointPath: cp, mine: mine, incoming: incoming, mineText: mineText, incomingText: incomingText)
        }
    }
    func writeCandidate(_ path: String, data: Data?) throws {
        guard let folder = workspace, GitRunner.isNotePath(path) else { throw GitFailure("Invalid sync result.") }
        let workspace = folder.resolvingSymlinksInPath()
        let file = workspace.appendingPathComponent(path)
        guard file.resolvingSymlinksInPath().path == workspace.resolvingSymlinksInPath().appendingPathComponent(path).standardizedFileURL.path else { throw GitFailure("The sync result cannot replace a symbolic link.") }
        if let data { try fm.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true); try data.write(to: file, options: .atomic) }
        else if fm.fileExists(atPath: file.path) { try fm.removeItem(at: file) }
        _ = try runner.git(["--literal-pathspecs", "add", "-A", "--", path], at: workspace, allowFailure: data == nil)
    }
    func candidate(_ path: String) throws -> Data? {
        guard let workspace else { return try blob(record.head, path) }
        let file = workspace.appendingPathComponent(path)
        return fm.fileExists(atPath: file.path) ? try Data(contentsOf: file) : nil
    }
    func conflicts() throws -> [GitReview] {
        guard let fetched = record.fetched else { return [] }
        let unmerged = Set(try unresolved()), notes = try notePaths()
        let mapping = Dictionary(uniqueKeysWithValues: notes.map { (checkpointPath($0), $0) })
        let paths = Set(unmerged.map { mapping[$0] ?? $0 }).union(record.manual.filter { !record.resolved.contains($0) }).sorted()
        let ancestor = try command(["merge-base", record.head, fetched])
        return try paths.map { path in
            GitReview(path: path, mine: try blob(record.head, path), incoming: try blob(fetched, path), base: try blob(ancestor, path), checkpointPath: mapping.values.contains(path) ? checkpointPath(path) : nil)
        }
    }
    func saveReview() throws {
        let data = try JSONEncoder().encode(record)
        try data.write(to: reviewFile, options: .atomic)
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: reviewFile.path)
        let handle = try FileHandle(forWritingTo: reviewFile); try handle.synchronize(); try handle.close()
    }
    // Called after the active web editor has merged the candidate in a single JS
    // transaction. Its latest Markdown + checkpoint replace the candidate pair.
    // Other files must still match the snapshot; otherwise the next pass retries.
    @discardableResult func apply(activePaths: Set<String> = []) throws -> String {
        guard try conflicts().isEmpty else { throw GitFailure("Review the conflicting copies before syncing.") }
        guard let workspace else {
            // A push of an immutable snapshot doesn't need to wait for typing.
            try validate(except: Set(record.baseline.keys).union(try workingSnapshot().keys))
            applied = true; return record.head
        }
        try validate(except: activePaths)
        for path in activePaths {
            let url = root.appendingPathComponent(path)
            try writeCandidate(path, data: fm.fileExists(atPath: url.path) ? Data(contentsOf: url) : nil)
        }
        // Commit edits made during the fetch, without changing any working file.
        try runner.commitNotes(root)
        let local = try command(["rev-parse", "HEAD"])
        record.head = local
        guard try runner.git(["diff", "--quiet"], at: root, allowFailure: true).status == 0 else { throw GitChangedDuringSync() }
        let tree = try command(["write-tree"], at: workspace)
        var args = ["commit-tree", tree, "-p", local]
        if let fetched = record.fetched, fetched != local { args += ["-p", fetched] }
        args += ["-m", "Sync notes in Omega"]
        let target: String
        if let fetched = record.fetched, try command(["rev-parse", fetched + "^{tree}"]) == tree,
           try runner.git(["merge-base", "--is-ancestor", local, fetched], at: root, allowFailure: true).status == 0 {
            target = fetched // Don't manufacture reciprocal empty merges every sync interval.
        } else { target = try command(args) }
        _ = try command(["update-ref", "refs/omega/backups/" + UUID().uuidString, target])
        // Git itself rejects incoming paths that would clobber an outside edit.
        _ = try command(["merge", "--ff-only", target])
        record.head = target; applied = true
        try? fm.removeItem(at: reviewFile)
        return target
    }
    func push(credentials: [String]) throws -> String {
        guard applied, try command(["symbolic-ref", "--short", "HEAD"]) == record.branch,
              try GitRemote(command(["config", "--get", "remote.origin.url"])).url == record.remoteURL else { throw GitChangedDuringSync() }
        _ = try runner.git(["push", "origin", record.head + ":" + record.remoteBranch], at: root, credentials: credentials)
        return "Up to date · " + record.branch
    }
    func discard() {
        if let workspace { _ = try? runner.git(["worktree", "remove", "--force", workspace.path], at: root) }
        try? fm.removeItem(at: reviewFile)
        releaseLock()
    }
}
