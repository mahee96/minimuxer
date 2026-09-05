//
//  BaseDeviceGateway.swift
//  Minimuxer
//
//  Created by Magesh K on 05/09/26.
//  Copyright © 2026 SideStore. All rights reserved.
//

import Foundation
import MinimuxerCommon

open class BaseDeviceGateway: @unchecked Sendable {
    public private(set) var pairingFileType: PairingProtocol = .unknown
    public private(set) var pairingDataDict: [String: any Sendable]? = nil

    public private(set) var pairingFileData: Data? = nil {
        didSet {
            guard let pairingFileData else {
                self.pairingDataDict = nil
                return
            }
            self.pairingDataDict = try? PropertyListSerialization.propertyList(
                from: pairingFileData,
                options: [],
                format: nil
            ) as? [String: any Sendable]
        }
    }

    public internal(set) var deviceEndpointIp: String? = nil
    public internal(set) var isInitialized: Bool = false
    private var protocolPorts: [PairingProtocol: UInt16] = [:]

    public init() {}

    public func setPairingFileData(_ data: Data?) {
        self.pairingFileData = data
    }

    public func setPairingFileType(_ type: PairingProtocol) {
        self.pairingFileType = type
    }

    public func setInitialized(_ initialized: Bool) {
        self.isInitialized = initialized
    }

    public func getPairingFileType() -> PairingProtocol {
        pairingFileType
    }

    public func getPort(for protocol: PairingProtocol) -> UInt16 {
        protocolPorts[`protocol`] ?? `protocol`.defaultPort
    }

    private var logTag: String {
        String(describing: type(of: self))
    }

    public func setPort(_ port: UInt16, for protocol: PairingProtocol) {
        debugLog("[\(logTag)] setPort(\(port), for: .\(`protocol`)) called")
        guard protocolPorts[`protocol`] != port else { return }
        protocolPorts[`protocol`] = port
        invalidateConnection()
    }

    public func setDeviceEndpointIp(_ ip: String?) {
        debugLog("[\(logTag)] setDeviceEndpointIp(\(ip ?? "nil")) called")
        guard deviceEndpointIp != ip else {
            debugLog("[\(logTag)] setDeviceEndpointIp: IP is already \(ip ?? "nil"), skipping invalidation")
            return
        }
        deviceEndpointIp = ip
        invalidateConnection()
    }

    open func setLogging(_ enabled: Bool) {
        DeviceGatewayLogging.setLogging(enabled)
        debugLog("[\(logTag)] setLogging(\(enabled)) called")
    }

    open func invalidateConnection() {
        // Subclasses override to invalidate cached handles/tunnels
    }
}
