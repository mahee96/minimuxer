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
        .binaryTarget(
            name: "IDevice",
            url: "https://github.com/SideStore/idevice/releases/download/v0.1.64-ss-499065c-ss-5c8e027/idevice-xcframework-v0.1.64-ss-499065c-ss-5c8e027.zip",
            checksum: "95d5e075bdc8d64f0d2df976e53d9f62129c76cba3b58be95ca11c3acdebf75f"
        ),
        // MARK: Main SPM target
        .target(
            name: "Minimuxer",
            dependencies: [
                "IDevice",
                .product(name: "ZIPFoundation", package: "ZIPFoundation")
            ],
            path: "Sources"
        )
    ]
)
