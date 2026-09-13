// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Matilde",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "Matilde", targets: ["Matilde"])],
    dependencies: [.package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.9.6")],
    targets: [
        .systemLibrary(name: "CSQLite"),
        .executableTarget(name: "Matilde", dependencies: ["CSQLite", .product(name: "Sparkle", package: "Sparkle")], resources: [.copy("Resources/Fonts")]),
        .testTarget(name: "MatildeTests", dependencies: ["Matilde"])
    ],
    swiftLanguageModes: [.v5]
)
