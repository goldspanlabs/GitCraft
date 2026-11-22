// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "MiniGit",
    platforms: [.macOS(.v13)],
    products: [.executable(name: "MiniGit", targets: ["MiniGit"])],
    targets: [
        .executableTarget(
            name: "MiniGit",
            path: "Sources",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("SwiftUI"),
                .linkedLibrary("minigit_core", .when(platforms: [.macOS])),
            ]
        )
    ]
)
