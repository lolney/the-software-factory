// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MultiAgentDesktop",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "MultiAgentDesktop", targets: ["MultiAgentDesktop"])
    ],
    targets: [
        .executableTarget(
            name: "MultiAgentDesktop",
            path: "Sources/MultiAgentDesktop"
        )
    ]
)
