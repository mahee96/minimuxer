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
            type: .dynamic,
            targets: ["Minimuxer"]
        )
    ],
    dependencies: [
        .package(
            url: "https://github.com/weichsel/ZIPFoundation.git",
            .upToNextMajor(from: "0.9.0")
        ),
        .package(path: "Sources/Common"),
        .package(path: "Sources/DeviceGateway")
    ],
    targets: [
        .binaryTarget(
            name: "EMProxy",
            url: "https://github.com/SideStore/em_proxy/releases/download/v0.9.2/EMProxy.xcframework.zip",
            checksum: "4a4ae57ae2e6e110484399a72b95fcdeda8db2aff658cf3793761371098dee08"
        ),
//         .binaryTarget(
//             name: "EMProxy",
//             path: "../../local/em_proxy/libs/EMProxy.xcframework"
//         ),

        // Main SPM target
        .target(
            name: "Minimuxer",
            dependencies: [
                .product(name: "MinimuxerCommon", package: "Common"),
                .product(name: "DeviceGatewayAPI", package: "DeviceGateway"),
                .product(name: "IdeviceGateway", package: "DeviceGateway"),
                .product(name: "LibimobiledeviceGateway", package: "DeviceGateway"),
                "EMProxy",
                .product(name: "ZIPFoundation", package: "ZIPFoundation")
            ],
            path: "Sources",
            exclude: [
                "Common",
                "DeviceGateway"
            ]
        ),
        .testTarget(
            name: "MinimuxerTests",
            dependencies: ["Minimuxer"],
            path: "Tests"
        )
    ],
    cLanguageStandard: .gnu11,
    cxxLanguageStandard: .gnucxx14
)
