// swift-tools-version:6.0
import PackageDescription

// Module graph mirrors the layout in CLAUDE.md. The macOS app shell
// (Sources/LoupeAppMain) is built by the Xcode project (project.yml), not SPM,
// so it is intentionally absent here.
let package = Package(
    name: "Loupe",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "LoupeCore", targets: ["LoupeCore"]),
        .library(name: "LoupeStore", targets: ["LoupeStore"]),
        .library(name: "LoupeSampler", targets: ["LoupeSampler"]),
        .library(name: "LoupeBench", targets: ["LoupeBench"]),
        .library(name: "LoupeApp", targets: ["LoupeApp"]),
        .executable(name: "loupedaemon", targets: ["loupedaemon"]),
        .executable(name: "loupe-record", targets: ["loupe-record"]),
        .executable(name: "loupe-llamacpp", targets: ["loupe-llamacpp"]),
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.5.0"),
        .package(url: "https://github.com/jpsim/Yams.git", from: "5.1.0"),
    ],
    targets: [
        .target(name: "LoupeCore"),
        .target(
            name: "LoupeStore",
            dependencies: [
                "LoupeCore",
                .product(name: "GRDB", package: "GRDB.swift"),
            ]
        ),
        .target(name: "LoupeSampler", dependencies: ["LoupeCore"]),
        .target(
            name: "LoupeBench",
            dependencies: [
                "LoupeCore",
                .product(name: "Yams", package: "Yams"),
            ]
        ),
        .target(
            name: "LoupeApp",
            dependencies: ["LoupeCore", "LoupeStore", "LoupeSampler"]
        ),
        .executableTarget(
            name: "loupedaemon",
            dependencies: ["LoupeCore", "LoupeSampler", "LoupeStore"]
        ),
        .executableTarget(
            name: "loupe-record",
            dependencies: ["LoupeCore", "LoupeSampler"]
        ),
        .executableTarget(
            name: "loupe-bench",
            dependencies: ["LoupeCore", "LoupeBench", "LoupeSampler"]
        ),
        .executableTarget(
            name: "loupe-llamacpp",
            dependencies: ["LoupeCore"],
            path: "adapters/loupe-llamacpp"
        ),
        .testTarget(name: "LoupeCoreTests", dependencies: ["LoupeCore"]),
        .testTarget(name: "LoupeBenchTests", dependencies: ["LoupeBench"]),
        .testTarget(name: "LoupeStoreTests", dependencies: ["LoupeStore"]),
        .testTarget(name: "LoupeSamplerTests", dependencies: ["LoupeSampler"]),
        .testTarget(name: "LoupeAppTests", dependencies: ["LoupeApp"]),
    ]
)
