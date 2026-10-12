import Foundation
import Darwin

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
    struct Output { let status: Int32; let text: String }
    var executable = URL(fileURLWithPath: "/usr/bin/git")
    var timeout: TimeInterval = 90
    static func cli(_ name: String) -> URL? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let directories = ["/opt/homebrew/bin", "/usr/local/bin", home + "/.local/bin", "/usr/bin"] + (ProcessInfo.processInfo.environment["PATH"] ?? "").components(separatedBy: ":")
        return directories.map { URL(fileURLWithPath: $0).appendingPathComponent(name) }.first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }
    func run(_ args: [String], in directory: URL, environment: [String: String] = [:], allowFailure: Bool = false) throws -> Output {
        let process = Process(), pipe = Pipe()
        process.executableURL = executable; process.arguments = args; process.currentDirectoryURL = directory
        var env = ProcessInfo.processInfo.environment
        // Do not inherit a terminal's alternate index/worktree or injected Git options.
        for key in env.keys where key.hasPrefix("GIT_") { env.removeValue(forKey: key) }
        env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:" + (env["PATH"] ?? "")
        env["GIT_TERMINAL_PROMPT"] = "0"; env["GCM_INTERACTIVE"] = "never"; env["GH_PROMPT_DISABLED"] = "1"; env["GLAB_CHECK_UPDATE"] = "false"
        env["LC_ALL"] = "C"; env.merge(environment, uniquingKeysWith: { _, new in new })
        process.environment = env; process.standardInput = FileHandle.nullDevice
        process.standardOutput = pipe; process.standardError = pipe
        let timeoutWork = DispatchWorkItem { if process.isRunning { process.terminate() } }
        try process.run()
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: timeoutWork)
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit(); timeoutWork.cancel()
        let result = Output(status: process.terminationStatus, text: String(decoding: data, as: UTF8.self))
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
        guard URL(fileURLWithPath: top).resolvingSymlinksInPath() == root.resolvingSymlinksInPath() else { throw GitFailure("Choose the repository’s top folder so its scope is clear.") }
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

    // Only Markdown/text and image attachments are automatically committed.
    // Hidden files, code, secrets, and any unrelated staged work stay out of sync.
    static func isNotePath(_ path: String) -> Bool {
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        return !parts.isEmpty && parts.allSatisfy { !$0.isEmpty && !$0.hasPrefix(".") } &&
            ["md", "markdown", "txt", "png", "jpg", "jpeg", "gif", "webp", "svg", "heic", "pdf"].contains(URL(fileURLWithPath: path).pathExtension.lowercased())
    }
    func sync(_ root: URL, credentials: [String]) throws -> String {
        let info = try inspect(root)
        let gitPath = try git(["rev-parse", "--absolute-git-dir"], at: root).text.trimmingCharacters(in: .whitespacesAndNewlines)
        let lock = open(gitPath + "/omega-sync.lock", O_CREAT | O_RDWR, 0o600)
        guard lock >= 0 else { throw GitFailure("Couldn’t lock this repository for sync.") }
        defer { close(lock) }
        guard flock(lock, LOCK_EX | LOCK_NB) == 0 else { throw GitFailure("This notebook is already syncing.") }
        defer { flock(lock, LOCK_UN) }
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
        let head = try git(["rev-parse", "HEAD"], at: root).text.trimmingCharacters(in: .whitespacesAndNewlines)
        let mergeRef = try git(["config", "--get", "branch.\(info.branch).merge"], at: root, allowFailure: true).text.trimmingCharacters(in: .whitespacesAndNewlines)
        let remoteBranch = mergeRef.isEmpty ? "refs/heads/" + info.branch : mergeRef
        guard remoteBranch.hasPrefix("refs/heads/"), try git(["check-ref-format", remoteBranch], at: root, allowFailure: true).status == 0 else { throw GitFailure("Choose a regular remote branch before syncing.") }
        let upstreamRemote = try git(["config", "--get", "branch.\(info.branch).remote"], at: root, allowFailure: true).text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard upstreamRemote.isEmpty || upstreamRemote == "origin" else { throw GitFailure("This branch tracks a different remote. Set its upstream to origin before syncing.") }
        let remoteHeads = try git(["ls-remote", "--heads", "origin", remoteBranch], at: root, credentials: credentials).text
        var target = head
        if !remoteHeads.isEmpty {
            _ = try git(["fetch", "--no-tags", "origin", remoteBranch], at: root, credentials: credentials)
            let fetched = try git(["rev-parse", "FETCH_HEAD"], at: root).text.trimmingCharacters(in: .whitespacesAndNewlines)
            if try git(["merge-base", "--is-ancestor", fetched, head], at: root, allowFailure: true).status != 0 {
                if try git(["merge-base", "--is-ancestor", head, fetched], at: root, allowFailure: true).status == 0 { target = fetched }
                else {
                    let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("Omega-Merge-" + UUID().uuidString)
                    _ = try git(["worktree", "add", "--detach", scratch.path, head], at: root)
                    defer { _ = try? git(["worktree", "remove", "--force", scratch.path], at: root) }
                    try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: scratch.path)
                    let merge = try git(["merge", "--no-edit", fetched], at: scratch, allowFailure: true)
                    guard merge.status == 0 else { throw GitFailure("Both copies changed the same content. Your local notes are untouched and saved in Git. Resolve the branch conflict in Git, then sync again.") }
                    target = try git(["rev-parse", "HEAD"], at: scratch).text.trimmingCharacters(in: .whitespacesAndNewlines)
                }
                // Editors or other tools may have changed files during the fetch/merge.
                guard try git(["rev-parse", "HEAD"], at: root).text.trimmingCharacters(in: .whitespacesAndNewlines) == head,
                      try git(["status", "--porcelain=v1"], at: root).text.isEmpty else { throw GitFailure("Files changed while syncing. They are safe locally; sync again when other edits finish.") }
                _ = try git(["update-ref", "refs/omega/backups/" + UUID().uuidString, head], at: root)
                _ = try git(["merge", "--ff-only", target], at: root)
            }
        }
        // No force pushes. If someone pushed meanwhile, Git rejects this and a retry merges safely.
        guard try git(["rev-parse", "HEAD"], at: root).text.trimmingCharacters(in: .whitespacesAndNewlines) == target,
              try git(["symbolic-ref", "--short", "HEAD"], at: root).text.trimmingCharacters(in: .whitespacesAndNewlines) == info.branch else {
            throw GitFailure("The active branch changed during sync. Your notes are safe; try again after other Git operations finish.")
        }
        // Push the reviewed commit, not a moving HEAD, in case another tool switches branches.
        _ = try git(["push", "origin", target + ":" + remoteBranch], at: root, credentials: credentials)
        return "Up to date · " + info.branch
    }
}
