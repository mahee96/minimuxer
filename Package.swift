// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Minimuxer",
    platforms: [
        .iOS(.v13),
        .macOS(.v11)
    ],
    products: [
        .library(
            name: "Minimuxer",
            targets: ["Minimuxer"]
        )
    ],
    dependencies: [
        .package(
            url: "https://github.com/weichsel/ZIPFoundation.git",
            .upToNextMajor(from: "0.9.0")
        )
    ],
    targets: [

        // MARK: Rust build plugin
        .plugin(
            name: "RustBuildPlugin",
            capability: .buildTool(),
            path: "Plugins/RustBuildPlugin"
        ),

        // MARK: Rust bridge (links static lib produced by cargo)
        .target(
            name: "RustBridge",
            path: "RustBridge",
            exclude: [
                "Cargo.toml",
                "Cargo.lock",
                "src",
                "target",
                "Makefile",
            ],
            sources: [
                "MinimuxerBridge.swift"
            ],
            linkerSettings: [
                .unsafeFlags([
                    "-L", "RustBridge/lib",
                    "-lrust_bridge"
                ])
            ]
        ),

        // MARK: Main library
        .target(
            name: "Minimuxer",
            dependencies: [
                "RustBridge",
                .product(name: "ZIPFoundation", package: "ZIPFoundation")
            ],
            path: "Sources",
            plugins: [
                .plugin(name: "RustBuildPlugin")
            ]
        )
    ]
)
