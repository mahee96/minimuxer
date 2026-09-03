//
//  DeviceGatewayAPI.swift
//  Minimuxer
//
//  Created by Magesh K on 22/08/26.
//  Copyright © 2026 SideStore. All rights reserved.
//

import Foundation
@_exported import MinimuxerCommon

public struct PairedDeviceRecord: Sendable {
    public let name: String
    public let model: String
    public let udid: String
    public let pairingFilePath: String
    
    public init(name: String, model: String, udid: String, pairingFilePath: String) {
        self.name = name
        self.model = model
        self.udid = udid
        self.pairingFilePath = pairingFilePath
    }
}

public protocol DeviceGatewayAPI: AnyObject, Sendable {
    var isRPPairing: Bool { get }
    var pairingFileType: PairingProtocol { get }
    var pairingFileData: Data? { get }
    var pairingDataDict: [String: Any]? { get }

    func start(pairingFileContent: String) async throws
    func setDeviceEndpointIp(_ ip: String?)
    func setLogging(_ enabled: Bool)
    func getPairingFileType() -> PairingProtocol

    func fetchUDID() async throws -> String?
    func getLockdownValue(key: String) async throws -> String?

    func isDDIMounted() async throws -> Bool
    func mountDeveloperImage(image: Data, signature: Data) async throws
    func mountPersonalizedDdi(image: Data, trustcache: Data, manifest: Data) async throws

    func installProvisioningProfile(profile: Data) async throws
    func removeProvisioningProfile(id: String) async throws
    func dumpProfiles(docsPath: String) async throws -> String
    func removeApp(bundleId: String) async throws
    func yeetAppAfc(bundleId: String, ipaBytes: Data) async throws
    func installIpa(bundleId: String) async throws
    func wipeContainer(identifier: String) async throws

    func debugApp(appId: String) async throws
    func debugProcess(pid: UInt32) async throws

    func performHeartbeat(interval: UInt64) async throws -> UInt64

    func startWirelessPair(
        hostName: String,
        hostModel: String,
        outPath: String,
        onReady: @escaping @Sendable (String, UInt16, [String: String]) -> Void,
        onPin: @escaping @Sendable (String) -> Void
    ) async throws -> PairedDeviceRecord

    func triggerWirelessPair(
        targetIp: String,
        targetPort: UInt16,
        hostName: String,
        hostModel: String,
        outPath: String,
        onRequestPin: @escaping @Sendable (@escaping @Sendable (String) -> Void) -> Void
    ) async throws -> PairedDeviceRecord

    func afcListDirectory(bundleId: String, path: String) async throws -> [String]
    func afcReadFile(bundleId: String, path: String) async throws -> Data
    func afcGetFileInfo(bundleId: String, path: String) async throws -> (isDirectory: Bool, fileSize: Int64)
}
