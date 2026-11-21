// swift-tools-version: 6.0
import PackageDescription

// Shared, platform-neutral Swift code for the Matilde apps (apps/macos, apps/ios):
// the workspace store (Markdown files plus SQLite), review data, the sync record model,
// end-to-end encryption, the sync client core and the Ask Matilde client.
// Foundation and CryptoKit only: no AppKit, UIKit or SwiftUI.
//
// On Apple platforms CryptoKit is used. On Linux (agent sandboxes, the Linux CI job) the same
// API comes from swift-crypto; the dependency is only declared there, so the apps never fetch it.
#if os(Linux)
let cryptoDependencies: [Package.Dependency] = [.package(url: "https://github.com/apple/swift-crypto", "3.0.0"..<"5.0.0")]
let cryptoProducts: [Target.Dependency] = [.product(name: "Crypto", package: "swift-crypto")]
#else
let cryptoDependencies: [Package.Dependency] = []
let cryptoProducts: [Target.Dependency] = []
#endif

let package = Package(
    name: "MatildeKit",
    platforms: [.macOS(.v14), .iOS(.v18)],
    products: [
        .library(name: "MatildeKit", targets: ["MatildeKit"]),
        // Test doubles shared by the package's tests and the apps' tests (an in-memory sync server).
        .library(name: "MatildeKitTesting", targets: ["MatildeKitTesting"])
    ],
    dependencies: cryptoDependencies,
    targets: [
        // System SQLite (macOS and iOS SDKs; libsqlite3-dev on Linux) for the workspace store.
        .systemLibrary(name: "CSQLite"),
        .target(name: "MatildeKit", dependencies: ["CSQLite"] + cryptoProducts),
        .target(name: "MatildeKitTesting", dependencies: ["MatildeKit"]),
        .testTarget(name: "MatildeKitTests", dependencies: ["MatildeKit", "MatildeKitTesting"] + cryptoProducts)
    ],
    swiftLanguageModes: [.v5]
)
