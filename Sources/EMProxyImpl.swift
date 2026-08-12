//
//  EMProxyImpl.swift
//  Minimuxer
//
//  Created by Magesh K on 12/8/26.
//  Copyright © 2026 SideStore. All rights reserved.
//

import Foundation
import EMProxy
import Network


public enum EMProxyError: Error, LocalizedError, CustomStringConvertible, Equatable, Sendable {
    case invalidBindAddressPointer
    case invalidUTF8String
    case invalidSocketAddress(String)
    case socketBindFailed
    case cryptoInitFailed
    case serverNotRunning
    case stopSignalFailed
    case threadJoinFailed
    case handshakeClientNotConfigured
    case unknownError(Int32)

    public var description: String {
        switch self {
        case .invalidBindAddressPointer:
            return "Invalid bind address pointer"
        case .invalidUTF8String:
            return "Failed to convert bind address to UTF-8"
        case .invalidSocketAddress(let addr):
            return "Invalid IPv4 socket address format: \(addr)"
        case .socketBindFailed:
            return "Failed to bind to UDP socket address"
        case .cryptoInitFailed:
            return "Failed to initialize EMProxy crypto keys"
        case .serverNotRunning:
            return "EMProxy server is not running"
        case .stopSignalFailed:
            return "Failed to send stop signal to EMProxy server"
        case .threadJoinFailed:
            return "Failed to join EMProxy loopback thread"
        case .handshakeClientNotConfigured:
            return "EMProxy WireGuard VPN handshake client not configured"
        case .unknownError(let code):
            return "EMProxy error code: \(code)"
        }
    }

    public var errorDescription: String? {
        return description
    }
}

public final class EMProxyImpl: @unchecked Sendable, EMProxyAPI {
    private struct HandshakeConfig: Sendable {
        let host: String
        let port: UInt16
        let enabled: Bool
    }
    private var handshakeConfig: HandshakeConfig?
    private let handshakeLock = NSLock()

    public func setHandshakeClient(host: String, port: UInt16, enabled: Bool) {
        handshakeLock.withLock {
            self.handshakeConfig = HandshakeConfig(host: host, port: port, enabled: enabled)
        }
    }

    public init() {
        set_log_callback { level, msgPtr in
            guard let msgPtr = msgPtr else { return false }
            let msg = "[EMProxy] \(String(cString: msgPtr))"
            if level <= 1 {
                verboseLog(msg)
            } else {
                debugLog(msg)
            }
            return true
        }
    }



    public func start(host: String, port: UInt16) async throws {
        let config = handshakeLock.withLock { self.handshakeConfig }
        guard let config = config else {
            throw EMProxyError.handshakeClientNotConfigured
        }
        let address = "\(host):\(port)"
        try await matchingPriority {
            try await withFFIDispatch {
                switch start_emotional_damage(address) {
                    case 0:
                        break
                    case -1:
                        throw EMProxyError.invalidBindAddressPointer
                    case -2:
                        throw EMProxyError.invalidUTF8String
                    case -3:
                        throw EMProxyError.invalidSocketAddress(address)
                    case -4:
                        throw EMProxyError.socketBindFailed
                    case -5:
                        throw EMProxyError.cryptoInitFailed
                    case let err:
                        throw EMProxyError.unknownError(err)
                }
            }
        }
        if config.enabled {
            await triggerVPNHandshake(host: config.host, port: config.port)
        }
    }

    public func stop() async throws {
        try await matchingPriority {
            try await withFFIDispatch {
                switch stop_emotional_damage() {
                    case 0:
                        return
                    case -1:
                        throw EMProxyError.serverNotRunning
                    case -2:
                        throw EMProxyError.stopSignalFailed
                    case -3:
                        throw EMProxyError.threadJoinFailed
                    case let err:
                        throw EMProxyError.unknownError(err)
                }
            }
        }
    }



    private func triggerVPNHandshake(host: String, port: UInt16) async {
        await withCheckedContinuation { continuation in
            let connection = NWConnection(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: port)!, using: .tcp)
            var resumed = false
            connection.stateUpdateHandler = { state in
                debugLog("[EMProxy] triggerVPNHandshake state: \(state)")
                switch state {
                    case .ready, .failed, .cancelled:
                        if !resumed {
                            resumed = true
                            continuation.resume()
                        }
                    default:
                        break
                }
            }
            connection.start(queue: .global())
            
            Task {
                try? await Task.sleep(nanoseconds: MinimuxerConstants.vpnHandshakeTimeoutNs)
                if !resumed {
                    resumed = true
                    continuation.resume()
                }
                connection.cancel()
            }
        }
    }
}
