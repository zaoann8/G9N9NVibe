// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "G9N9N-Vibe",
    platforms: [.macOS(.v12)],
    targets: [
        .executableTarget(
            name: "G9N9NVibe",
            path: "Sources/G9N9NVibe",
            swiftSettings: [
                .define("DEBUG", .when(configuration: .debug)),
                .unsafeFlags(["-Osize"], .when(configuration: .release)),
            ]
        )
    ]
)
