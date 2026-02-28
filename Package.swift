// swift-tools-version: 5.7
import PackageDescription

let package = Package(
    name: "Minimuxer",
    platforms: [
        .iOS(.v13),
        .macOS(.v11)
    ],
    products: [
        // .library(name: "RustBridge", targets: ["RustBridge"]),
        .library(name: "Minimuxer", targets: ["Minimuxer"])
    ],
    targets: [
        .target(
            name: "RustBridge",
            path: "Sources/RustBridge",
            exclude: ["Cargo.toml", "Cargo.lock", "src", "target", "lib"],
            sources: ["MinimuxerBridge.swift"],
            linkerSettings: [
                .unsafeFlags([
                    "-LSources/RustBridge/lib",
                    "-lrust_bridge"
                ])
            ]
        ),
        .target(
            name: "Minimuxer",
            dependencies: ["RustBridge"],
            path: "Sources/Minimuxer"
        )
    ]
)
