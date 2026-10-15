// swift-tools-version:6.2
import PackageDescription

// Data services shared by the shipping Mac app and the Linux port. The Mac
// bundle still uses build.sh; this package does not replace its native UI.
let package = Package(
    name: "OmegaCore",
    platforms: [.macOS(.v14)],
    products: [.library(name: "OmegaCore", targets: ["OmegaCore"])],
    dependencies: [.package(url: "https://github.com/apple/swift-crypto.git", exact: "5.0.1")],
    targets: [
        .systemLibrary(name: "CSQLite", path: "Portable/CSQLite", pkgConfig: "sqlite3", providers: [.apt(["libsqlite3-dev"])]),
        .target(name: "OmegaCore", dependencies: [.target(name: "CSQLite", condition: .when(platforms: [.linux])), .product(name: "Crypto", package: "swift-crypto", condition: .when(platforms: [.linux]))], path: ".",
                exclude: ["Editor", "Resources", "Relay", "Website", "Tests", "Portable"],
                sources: ["Core.swift", "Checklist.swift", "Recovery.swift", "UndoHistory.swift", "GitSync.swift", "GitMerge.swift", "LiveCheckpointStore.swift"]),
        .testTarget(name: "OmegaCoreTests", dependencies: ["OmegaCore"], path: "Tests",
                    sources: ["PortableCheck.swift", "GitSyncCheck.swift", "GitAutoSyncCheck.swift", "NoteLinkCheck.swift"])
    ],
    swiftLanguageModes: [.v5]
)
