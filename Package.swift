// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "MachinePulse",
    platforms: [
        .macOS(.v15)
    ],
    products: [
        .library(name: "MachinePulseCore", targets: ["MachinePulseCore"]),
        .executable(name: "MachinePulseApp", targets: ["MachinePulseApp"]),
        .executable(name: "MachinePulseVerifier", targets: ["MachinePulseVerifier"]),
        .executable(name: "MachinePulseXDRFixture", targets: ["MachinePulseXDRFixture"]),
    ],
    dependencies: [
        .package(
            url: "https://github.com/swiftlang/swift-testing.git",
            revision: "c9d57c83568b06da229ed24339a6228e8e3b438b"
        )
    ],
    targets: [
        .target(
            name: "MachinePulseCore",
            linkerSettings: [
                .linkedLibrary("sqlite3")
            ]
        ),
        .executableTarget(
            name: "MachinePulseApp",
            dependencies: ["MachinePulseCore"],
            resources: [.process("Resources")]
        ),
        .executableTarget(
            name: "MachinePulseVerifier",
            dependencies: ["MachinePulseCore"]
        ),
        .executableTarget(name: "MachinePulseXDRFixture"),
        .testTarget(
            name: "MachinePulseCoreTests",
            dependencies: [
                "MachinePulseCore",
                .product(name: "Testing", package: "swift-testing"),
            ],
            resources: [.process("Fixtures")]
        ),
    ],
    swiftLanguageModes: [.v6]
)
