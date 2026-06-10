// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "AIGlass",
    platforms: [.macOS("26.0")],
    products: [
        .executable(name: "AIGlass", targets: ["AIGlass"]),
    ],
    targets: [
        .target(
            name: "AIGlassCore",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "AIGlass",
            dependencies: ["AIGlassCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "AIGlassCoreTests",
            dependencies: ["AIGlassCore", "AIGlass"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
