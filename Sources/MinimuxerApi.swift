//
//  MinimuxerApi.swift
//  Minimuxer
//
//  Created by Magesh K on 4/7/26.
//  Copyright © 2026 SideStore. All rights reserved.
//

import Foundation

public enum MinimuxerComponent: String {
    case heartbeat
    case mounter
}

public enum RestartStatus {
    case ready(MinimuxerComponent)
    case failed(MinimuxerComponent, Error)
}

public struct TunnelConfigBinding: Sendable {
    public let setDeviceIP: @Sendable (String?) -> Void
    public let setFakeIP: @Sendable (String?) -> Void
    public let setSubnetMask: @Sendable (String?) -> Void
    public let getOverrideFakeIP: @Sendable () -> String
    public let setOverrideEffective: @Sendable (Bool) -> Void

    public init(
        setDeviceIP: @escaping @Sendable (String?) -> Void,
        setFakeIP: @escaping @Sendable (String?) -> Void,
        setSubnetMask: @escaping @Sendable (String?) -> Void,
        getOverrideFakeIP: @escaping @Sendable () -> String,
        setOverrideEffective: @escaping @Sendable (Bool) -> Void
    ) {
        self.setDeviceIP = setDeviceIP
        self.setFakeIP = setFakeIP
        self.setSubnetMask = setSubnetMask
        self.getOverrideFakeIP = getOverrideFakeIP
        self.setOverrideEffective = setOverrideEffective
    }
}

public protocol MinimuxerAPI: AnyObject {
    var isLoggingEnabled: Bool { get }
    var onBackgroundError: ((Error) async -> Void)? { get set }
    
    func describeError(_ error: MinimuxerError) -> String
    func bindTunnelConfig(_ binding: TunnelConfigBinding)
    func ready() -> Result<Bool, MinimuxerError>
    func setLogging(_ enabled: Bool)
    func reinitializePairingData(pairingFile: String) throws
    func start(pairingFile: String) throws
    func retargetUsbmuxdAddr()
    func fetchUDID() -> String?
    func testDeviceConnection(ifaddr: String?) -> Bool
    func yeetAppAfc(bundleId: String, ipaBytes: Data) throws
    func installIpa(bundleId: String) throws
    func removeApp(bundleId: String) throws
    func debugApp(appId: String) throws
    func attachDebugger(pid: UInt32) throws
    func startAutoMounter(docsPath: String) async
    func restart() async throws
    func checkAndNotify(_ status: RestartStatus) async
    func installProvisioningProfile(profile: Data) throws
    func removeProvisioningProfile(id: String) throws
    func dumpProfiles(docsPath: String) throws -> String
}

public enum Minimuxer {
    public static let shared: any MinimuxerAPI = MinimuxerImpl()
    public static let network: any NetworkObserverAPI = NetworkObserverService()
    public static let wirelessPair: any WirelessPairAPI = WirelessPairService()
}

// MARK: - Network Observer API

public protocol NetworkObserverAPI: AnyObject {
    var isWifiSatisfied: Bool { get }
    var isWiredSatisfied: Bool { get }
    var isBridgeSatisfied: Bool { get }

    @discardableResult
    func start() -> Bool
    
    @discardableResult
    func stop() -> Bool

    func refreshEndpoint()
}

// MARK: - Wireless Pair API

public struct WirelessPairPairedDevice: Sendable {
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

public protocol WirelessPairAPI: AnyObject {
    var onPinReceived: ((String) -> Void)? { get set }
    var onReadyToPair: ((String, Int) -> Void)? { get set }
    
    func start(
        hostName: String,
        hostModel: String,
        outPath: String,
        completion: @escaping (Result<WirelessPairPairedDevice, Swift.Error>) -> Void
    )
    
    func stop()
}

public extension WirelessPairAPI {
    func start(
        outPath: String,
        completion: @escaping (Result<WirelessPairPairedDevice, Swift.Error>) -> Void
    ){
        start(
            hostName: MinimuxerConstants.defaultHostName,
            hostModel: MinimuxerConstants.defaultHostModel,
            outPath: outPath,
            completion: completion
        )
    }
}
