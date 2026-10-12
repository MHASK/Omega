import AppKit
import SwiftUI
import CryptoKit

struct OmegaUpdateManifest: Codable {
    let schema: Int
    let version: String
    let build: Int
    let architecture: String
    let minimumSystemVersion: String
    let archive: String
    let sha256: String
    let size: Int
    func validate(repository: String) throws -> URL {
        guard schema == 1, build > 0, architecture == "arm64",
              version.range(of: #"^\d+\.\d+\.\d+$"#, options: .regularExpression) != nil,
              minimumSystemVersion.range(of: #"^\d+\.\d+(\.\d+)?$"#, options: .regularExpression) != nil,
              sha256.range(of: #"^[a-f0-9]{64}$"#, options: .regularExpression) != nil,
              size > 0, size <= 100_000_000,
              let url = URL(string: archive), url.scheme == "https", url.host == "github.com",
              url.user == nil, url.password == nil, url.query == nil, url.fragment == nil,
              url.path == "/\(repository)/releases/download/v\(version)/Omega-\(version).zip"
        else { throw FolioUpdates.Failure(message: "This release has an invalid update manifest.") }
        return url
    }
}

enum OmegaReleaseFeed {
    static let repository = "MHASK/Omega"
    static let home = URL(string: "https://github.com/" + repository)!
    struct Release: Decodable {
        struct Asset: Decodable { let name: String; let browser_download_url: String }
        let tag_name: String
        let prerelease: Bool
        let draft: Bool
        let assets: [Asset]
    }
    static func request(_ url: URL, timeout: TimeInterval = 45) -> URLRequest {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: timeout)
        request.setValue("Omega-macOS", forHTTPHeaderField: "User-Agent")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        return request
    }
    static func checkResponse(_ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            let message = status == 404 ? "No published update is available yet." : (status == 403 || status == 429 ? "GitHub is busy. Please check again later." : "Couldn't reach the update server. Please try again later.")
            throw FolioUpdates.Failure(message: message)
        }
    }
    static func latest(session: URLSession) async throws -> OmegaUpdateManifest {
        let (data, response) = try await session.data(for: request(URL(string: "https://api.github.com/repos/\(repository)/releases/latest")!))
        try checkResponse(response)
        guard data.count < 2_000_000 else { throw FolioUpdates.Failure(message: "The release information is too large.") }
        let release = try JSONDecoder().decode(Release.self, from: data)
        guard !release.draft, !release.prerelease, let asset = release.assets.first(where: { $0.name == "Omega-update.json" }),
              let url = URL(string: asset.browser_download_url), url.scheme == "https", url.host == "github.com",
              url.path == "/\(repository)/releases/download/\(release.tag_name)/Omega-update.json", url.query == nil, url.fragment == nil
        else { throw FolioUpdates.Failure(message: "This release doesn't contain an automatic update yet.") }
        let (manifestData, manifestResponse) = try await session.data(for: request(url))
        try checkResponse(manifestResponse)
        guard manifestData.count < 16_384 else { throw FolioUpdates.Failure(message: "The update manifest is too large.") }
        let manifest = try JSONDecoder().decode(OmegaUpdateManifest.self, from: manifestData)
        _ = try manifest.validate(repository: repository)
        guard release.tag_name == "v" + manifest.version else { throw FolioUpdates.Failure(message: "The release version doesn't match its update.") }
        return manifest
    }
    static func download(_ manifest: OmegaUpdateManifest, session: URLSession, currentBuild: Int) async throws -> URL {
        let url = try manifest.validate(repository: repository)
        guard manifest.build > currentBuild else { throw FolioUpdates.Failure(message: "This update is not newer than your installed app.") }
        let os = ProcessInfo.processInfo.operatingSystemVersion
        guard "\(os.majorVersion).\(os.minorVersion).\(os.patchVersion)".compare(manifest.minimumSystemVersion, options: .numeric) != .orderedAscending else { throw FolioUpdates.Failure(message: "Omega \(manifest.version) needs macOS \(manifest.minimumSystemVersion) or later.") }
        let fm = FileManager.default
        let cache = fm.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("local.folio.notes/Updates").resolvingSymlinksInPath()
        try fm.createDirectory(at: cache, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let folder = cache.appendingPathComponent(UUID().uuidString)
        try fm.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        do {
            let (temporary, response) = try await session.download(for: request(url, timeout: 180))
            defer { try? fm.removeItem(at: temporary) }
            try checkResponse(response)
            let fileSize = try temporary.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            guard fileSize == manifest.size else { throw FolioUpdates.Failure(message: "The update download is incomplete. Please try again.") }
            let data = try Data(contentsOf: temporary, options: .mappedIfSafe)
            let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            guard digest == manifest.sha256 else { throw FolioUpdates.Failure(message: "The update download couldn't be verified. Your app hasn't changed.") }
            let archive = folder.appendingPathComponent("update.zip")
            try fm.moveItem(at: temporary, to: archive)
            let candidate = try unpack(archive, in: folder)
            try FolioUpdates.verify(candidate, newerThan: currentBuild)
            let info = try FolioUpdates.info(candidate)
            guard info["CFBundleVersion"] as? String == String(manifest.build), info["CFBundleShortVersionString"] as? String == manifest.version else { throw FolioUpdates.Failure(message: "The signed app doesn't match this release.") }
            try? fm.removeItem(at: archive)
            return candidate
        } catch { try? fm.removeItem(at: folder); throw error }
    }
    static func command(_ arguments: [String]) throws -> String {
        let process = Process(), output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/tar"); process.arguments = arguments
        process.standardOutput = output; process.standardError = FileHandle.nullDevice
        try process.run()
        let result = output.fileHandleForReading.readDataToEndOfFile(); process.waitUntilExit()
        guard process.terminationStatus == 0, result.count < 4_000_000, let text = String(data: result, encoding: .utf8) else { throw FolioUpdates.Failure(message: "The update archive couldn't be opened.") }
        return text
    }
    static func validateEntries(_ paths: String, details: String) throws {
        let entries = paths.split(separator: "\n"), metadata = details.split(separator: "\n")
        guard !entries.isEmpty, entries.count <= 4096, entries.count == metadata.count else { throw FolioUpdates.Failure(message: "The update archive contains unexpected files.") }
        var total = 0
        for (path, info) in zip(entries, metadata) {
            let parts = path.split(separator: "/", omittingEmptySubsequences: false)
            let fields = info.split(whereSeparator: { $0.isWhitespace })
            guard path.hasPrefix("Omega.app/"), !path.contains("\\"), !path.contains("\r"),
                  !parts.contains(".."), !parts.contains("."),
                  info.first == "-" || info.first == "d", fields.count >= 9,
                  let bytes = Int(fields[4]), bytes >= 0, bytes <= 200_000_000 else { throw FolioUpdates.Failure(message: "The update archive contains an unsafe entry.") }
            total += bytes
            guard total <= 300_000_000 else { throw FolioUpdates.Failure(message: "The extracted update is too large.") }
        }
    }
    static func unpack(_ archive: URL, in folder: URL) throws -> URL {
        try validateEntries(command(["-tf", archive.path]), details: command(["-tvf", archive.path]))
        _ = try command(["-xf", archive.path, "-C", folder.path, "--no-same-owner", "--no-same-permissions"])
        return folder.appendingPathComponent("Omega.app").resolvingSymlinksInPath()
    }
}

@MainActor final class GitHubUpdater: ObservableObject {
    static let shared = GitHubUpdater()
    @Published var automatic = UserDefaults.standard.object(forKey: "automaticUpdates") as? Bool ?? true {
        didSet { UserDefaults.standard.set(automatic, forKey: "automaticUpdates"); if automatic { check() } }
    }
    @Published private(set) var busy = false
    @Published private(set) var message = "Updates come directly from Omega’s GitHub releases."
    @Published private(set) var readyVersion: String?
    @Published private(set) var error = false
    @Published private(set) var lastCheck: Date? = UserDefaults.standard.object(forKey: "lastUpdateCheck") as? Date
    private var candidate: URL?
    private var timer: Timer?
    private weak var notebook: Notebook?
    private var willQuit: (() -> Void)?
    private let session: URLSession = { let config = URLSessionConfiguration.ephemeral; config.timeoutIntervalForResource = 240; return URLSession(configuration: config) }()
    var currentBuild: Int { Int(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0") ?? 0 }
    func start(notebook: Notebook, willQuit: @escaping () -> Void) {
        self.notebook = notebook; self.willQuit = willQuit
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 6 * 60 * 60, repeats: true) { [weak self] _ in Task { @MainActor in if self?.automatic == true { self?.check() } } }
        DispatchQueue.main.asyncAfter(deadline: .now() + 20) { [weak self] in
            guard let self, self.automatic, Date().timeIntervalSince(self.lastCheck ?? .distantPast) > 6 * 60 * 60 else { return }; self.check()
        }
    }
    func check() {
        guard !busy, candidate == nil else { return }
        busy = true; error = false; message = "Checking for updates…"
        let session = self.session, build = currentBuild
        Task {
            do {
                let release = try await OmegaReleaseFeed.latest(session: session)
                lastCheck = Date(); UserDefaults.standard.set(lastCheck, forKey: "lastUpdateCheck")
                guard release.build > build else { message = "You’re up to date."; busy = false; return }
                message = "Downloading Omega \(release.version)…"
                let app = try await Task.detached { try await OmegaReleaseFeed.download(release, session: session, currentBuild: build) }.value
                candidate = app; readyVersion = release.version; message = "Omega \(release.version) is ready. Restart whenever you’re ready."
            } catch { self.error = true; message = error.localizedDescription }
            busy = false
        }
    }
    func install() {
        guard let candidate, let notebook, let willQuit else { return }
        FolioUpdates.install(candidate, notebook: notebook, willQuit: willQuit)
    }
}

