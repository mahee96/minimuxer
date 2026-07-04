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
//        .binaryTarget(
//            name: "RustBridgeLib",
//            path: "RustBridge/lib/RustBridge.xcframework"
//        ),
        .binaryTarget(
            name: "IDevice",
            url: "https://github.com/jkcoxson/idevice/releases/download/v0.1.64/idevice-xcframework-v0.1.64.zip",
            checksum: "b8250402a23c850f80b9be1d4add309aae6c935ee6a797b73616e4d8f170be5d"
        ),
//        .target(
//            name: "RustBridge",
//            dependencies: ["RustBridgeLib"],
//            path: "RustBridge",
//            exclude: [
//                "Cargo.toml",
//                "Cargo.lock",
//                "src",
//                "Makefile",
//                "lib",
//                // "MinimuxerBridgeIdevice.swift"
//            ],
//            sources: [
//                "MinimuxerBridge.swift",
//                // "MinimuxerBridgeIdevice.swift"
//            ]
//        ),
        // MARK: Main SPM target
        .target(
            name: "Minimuxer",
            dependencies: [
//                "RustBridge",
                "IDevice",
                .product(name: "ZIPFoundation", package: "ZIPFoundation")
            ],
            path: "Sources"
        )
    ]
)
