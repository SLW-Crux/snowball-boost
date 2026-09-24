// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "SnowballBoost",
    platforms: [.macOS(.v15)],
    targets: [
        .target(
            name: "BoostDSP",
            path: "Sources/BoostDSP",
            publicHeadersPath: "include"
        ),
        .testTarget(
            name: "BoostDSPTests",
            dependencies: ["BoostDSP"],
            path: "Tests/BoostDSPTests"
        ),
        .target(
            name: "SnowballCore",
            dependencies: ["BoostDSP"],
            path: "Sources/SnowballCore"
        ),
        .testTarget(
            name: "SnowballCoreTests",
            dependencies: ["SnowballCore"],
            path: "Tests/SnowballCoreTests"
        ),
        .executableTarget(
            name: "sbboost",
            dependencies: ["SnowballCore", "BoostDSP"],
            path: "Sources/sbboost",
            linkerSettings: [
                .unsafeFlags([
                    "-Xlinker", "-sectcreate",
                    "-Xlinker", "__TEXT",
                    "-Xlinker", "__info_plist",
                    "-Xlinker", "Resources/CLI-Info.plist",
                ])
            ]
        ),
        .executableTarget(
            name: "SnowballBoostApp",
            dependencies: ["SnowballCore"],
            path: "Sources/SnowballBoostApp"
        ),
    ]
)
