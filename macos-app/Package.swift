// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "GitCraft",
    platforms: [.macOS(.v13)],
    products: [.executable(name: "GitCraft", targets: ["GitCraft"])],
    targets: [
        .executableTarget(
            name: "GitCraft",
            path: "Sources",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("SwiftUI"),
                .linkedLibrary("gitcraft_core", .when(platforms: [.macOS])),
            ]
        )
    ]
)
