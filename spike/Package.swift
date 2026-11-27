// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "anvil-spike",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "anvil-spike",
            path: "Sources/anvil-spike",
            swiftSettings: [
                .defaultIsolation(MainActor.self)
            ]
        )
    ]
)
