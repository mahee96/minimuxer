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
            url: "https://github.com/SideStore/idevice/releases/download/v0.1.64-ss-b1dac43/idevice-xcframework-v0.1.64-ss-b1dac43.zip",
            checksum: "2d0d102051ee0633d451e95faecf5536f85e35a2cb090bde48a85e49d6259e95"
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
