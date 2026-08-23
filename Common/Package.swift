// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "MinimuxerCommon",
    platforms: [
        .iOS(.v14),
        .macOS(.v11)
    ],
    products: [
        .library(
            name: "MinimuxerCommon",
            targets: ["MinimuxerCommon"]
        )
    ],
    targets: [
        .target(
            name: "MinimuxerCommon",
            path: ".",
            sources: [
                "FFIDispatcher.swift",
                "MinimuxerConstants.swift",
                "NetworkUtils.swift"
            ]
        )
    ]
)
