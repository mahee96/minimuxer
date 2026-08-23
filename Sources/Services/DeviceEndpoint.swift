//
//  DeviceEndpoint.swift
//  Minimuxer
//
//  Original Rust Implementation by @jkcoxson
//  Swift Port created by Magesh K on 02/03/26.
//  Copyright © 2026 SideStore. All rights reserved.
//

import Foundation
internal import DeviceGatewayAPI

actor DeviceEndpoint {

    static let shared = DeviceEndpoint()

    private var gateway: any DeviceGatewayAPI { Minimuxer.gateway }

    private var ipAddr: String? = nil

    private init() {}

    func ip() throws -> String {
        guard let ip = ipAddr else { throw MinimuxerInternalError.deviceEndpointNotInitialized }
        return ip
    }

    func update(_ newIP: String) {
        ipAddr = newIP
        self.gateway.setDeviceEndpointIp(newIP)
        verboseLog("[minimuxer] device endpoint updated -> \(newIP)")
    }

    func clear() {
        ipAddr = nil
        self.gateway.setDeviceEndpointIp(nil)
        verboseLog("[minimuxer] device endpoint cleared -> nil")
    }

    var isInitialized: Bool {
        ipAddr != nil
    }
}
