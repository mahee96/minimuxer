//
//  TunnelPeer.swift
//  Minimuxer
//
//  Original Rust Implementation by @jkcoxson
//  Swift Port created by Magesh K on 02/03/26.
//

import Foundation

actor TunnelPeer {

    static let shared = TunnelPeer()

    private var ipAddr: String? = nil

    private init() {}

    func ip() throws -> String {
        guard let ip = ipAddr else { throw MinimuxerInternalError.tunnelPeerNotInitialized }
        return ip
    }

    func update(_ newIP: String) {
        ipAddr = newIP
        IdeviceGateway.shared.setTunnelPeerIp(newIP)
        verboseLog("[minimuxer] tunnel peer updated -> \(newIP)")
    }

    func clear() {
        ipAddr = nil
        IdeviceGateway.shared.setTunnelPeerIp(nil)
        verboseLog("[minimuxer] tunnel peer cleared -> nil")
    }

    var isInitialized: Bool {
        ipAddr != nil
    }
}
