// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "TheSoftwareFactory",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "TheSoftwareFactory", targets: ["TheSoftwareFactory"])
    ],
    targets: [
        .executableTarget(
            name: "TheSoftwareFactory",
            path: "Sources/MultiAgentDesktop"
        ),
        .testTarget(
            name: "TheSoftwareFactoryTests",
            dependencies: ["TheSoftwareFactory"],
            path: "Tests/MultiAgentDesktopTests"
        )
    ]
)
