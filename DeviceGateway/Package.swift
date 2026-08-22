// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "MinimuxerDeviceGateway",
    platforms: [
        .iOS(.v13),
        .macOS(.v11)
    ],
    products: [
        .library(
            name: "DeviceGatewayAPI",
            targets: ["DeviceGatewayAPI"]
        ),
        .library(
            name: "IdeviceGateway",
            type: .dynamic,
            targets: ["IdeviceGateway"]
        ),
        .library(
            name: "LibimobiledeviceGateway",
            type: .dynamic,
            targets: ["LibimobiledeviceGateway"]
        )
    ],
    dependencies: [
        .package(path: "../Common")
    ],
    targets: [
//        .binaryTarget(
//            name: "IDevice",
//            url: "https://github.com/jkcoxson/idevice/releases/download/v0.1.64/idevice-xcframework-v0.1.64.zip",
//            checksum: "b8250402a23c850f80b9be1d4add309aae6c935ee6a797b73616e4d8f170be5d"
//        ),
         .binaryTarget(
             name: "IDevice",
             url: "https://github.com/SideStore/idevice/releases/download/v0.1.65-ss-895f502/idevice-xcframework-v0.1.65-ss-895f502.zip",
             checksum: "6dbc7589b5796a5ec1f622e3e7a5e7a999adb2a5b58c876faa63b26c513f1610"
         ),
//        .binaryTarget(
//            name: "IDevice",
//            path: "../../local/idevice/swift/bundle.zip"
//        ),
        .binaryTarget(
            name: "libimobiledevice",
            url: "https://github.com/SideStore/libimobiledevice-xcframework/releases/download/1.4.0-ss-ab5f627/libimobiledevice.xcframework.zip",
            checksum: "8a34a3420eb97e25cdb5b3ed1c518fdebda399e7cdedf43d5a901442f3aef5fb"
        ),
//        .binaryTarget(
//            name: "libimobiledevice",
//            path: "../../local/libimobiledevice-xcframework/libs/libimobiledevice.xcframework"
//        ),

        // Base API Target
        .target(
            name: "DeviceGatewayAPI",
            path: ".",
            exclude: [
                "idevice",
                "libimobiledevice"
            ],
            sources: [
                "DeviceGatewayAPI.swift",
                "DeviceGatewayError.swift",
                "DeviceGatewayLogging.swift",
                "PairingProtocol.swift"
            ]
        ),

        // Dynamic Idevice Target
        .target(
            name: "IdeviceGateway",
            dependencies: [
                "DeviceGatewayAPI",
                .product(name: "MinimuxerCommon", package: "Common"),
                "IDevice"
            ],
            path: "idevice"
        ),

        // Dynamic Libimobiledevice Target
        .target(
            name: "LibimobiledeviceGateway",
            dependencies: [
                "DeviceGatewayAPI",
                .product(name: "MinimuxerCommon", package: "Common"),
                "libimobiledevice"
            ],
            path: "libimobiledevice",
            linkerSettings: [
                .unsafeFlags(["-undefined", "dynamic_lookup"])
            ]
        )
    ]
)
