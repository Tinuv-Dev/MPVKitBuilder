// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "MPVKitBuilder",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "MPVKitBuilder",
            path: "Sources/MPVKitBuilder",
            exclude: ["Resources/Patch/.gitkeep"],
            resources: [
                .copy("Resources/Patch"),
            ]
        ),
    ]
)
