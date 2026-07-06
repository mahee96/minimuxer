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
//            name: "IDevice",
//            url: "https://github.com/jkcoxson/idevice/releases/download/v0.1.64/idevice-xcframework-v0.1.64.zip",
//            checksum: "b8250402a23c850f80b9be1d4add309aae6c935ee6a797b73616e4d8f170be5d"
//        ),
        .binaryTarget(
            name: "IDevice",
            url: "https://github.com/SideStore/idevice/releases/download/v0.1.64-ss-b1dac43/idevice-xcframework-v0.1.64-ss-b1dac43.zip",
            checksum: "ee7cfc58aa64b97239fa9fdb57b1632a2f45725f7fa4187517184b32de43fb89"
        ),
//         .binaryTarget(
//             name: "IDevice",
//             path: "../../local/idevice/swift/bundle.zip"
//         ),
        
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
