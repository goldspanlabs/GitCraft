// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "GitCraft",
    platforms: [.macOS("15.0")],
    products: [.executable(name: "GitCraft", targets: ["GitCraft"])],
    targets: [
        .executableTarget(
            name: "GitCraft",
            path: "Sources",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("SwiftUI"),
                .linkedFramework("WebKit"),
                .linkedLibrary("gitcraft_core", .when(platforms: [.macOS])),
            ]
        ),
        .testTarget(
            name: "GitCraftTests",
            dependencies: ["GitCraft"],
            path: "Tests/GitCraftTests"
        ),
    ]
)
