// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Matilde",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "Matilde", targets: ["Matilde"])],
    targets: [
        .systemLibrary(name: "CSQLite"),
        .executableTarget(name: "Matilde", dependencies: ["CSQLite"], resources: [.copy("Resources/Fonts")]),
        .testTarget(name: "MatildeTests", dependencies: ["Matilde"])
    ],
    swiftLanguageModes: [.v5]
)
