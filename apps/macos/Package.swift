// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Matilde",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "Matilde", targets: ["Matilde"])],
    dependencies: [
        .package(path: "../../packages/MatildeKit"),
        .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.9.6")
    ],
    targets: [
        .executableTarget(name: "Matilde", dependencies: [.product(name: "MatildeKit", package: "MatildeKit"), .product(name: "Sparkle", package: "Sparkle")], resources: [.copy("Resources/Fonts"), .copy("Resources/Icons"), .copy("Resources/AppIcons")]),
        .testTarget(name: "MatildeTests", dependencies: ["Matilde", .product(name: "MatildeKit", package: "MatildeKit"), .product(name: "MatildeKitTesting", package: "MatildeKit")])
    ],
    swiftLanguageModes: [.v5]
)
