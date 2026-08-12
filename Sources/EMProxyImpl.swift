//
//  EMProxyImpl.swift
//  Minimuxer
//
//  Created by Magesh K on 12/8/26.
//  Copyright © 2026 SideStore. All rights reserved.
//

import Foundation
import EMProxy

public enum EMProxyError: Error, LocalizedError, CustomStringConvertible, Equatable, Sendable {
    case invalidBindAddressPointer
    case invalidUTF8String
    case invalidSocketAddress(String)
    case socketBindFailed
    case cryptoInitFailed
    case serverNotRunning
    case stopSignalFailed
    case threadJoinFailed
    case testConnectionFailed
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
        case .testConnectionFailed:
            return "EMProxy loopback test connection failed"
        case .unknownError(let code):
            return "EMProxy error code: \(code)"
        }
    }

    public var errorDescription: String? {
        return description
    }
}

public final class EMProxyImpl: EMProxyAPI {
    public init() {
        set_log_callback { level, msgPtr in
            guard let msgPtr = msgPtr else { return false }
            let msg = "[em_proxy] \(String(cString: msgPtr))"
            if level <= 1 {
                verboseLog(msg)
            } else {
                debugLog(msg)
            }
            return true
        }
    }



    public func start(host: String, port: UInt16) async throws {
        let address = "\(host):\(port)"
        try await matchingPriority {
            try await withFFIDispatch {
                switch start_emotional_damage(address) {
                    case 0:
                        return
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

    public func testConnection(timeoutMs: Int32) async throws {
        try await matchingPriority {
            try await withFFIDispatch {
                switch test_emotional_damage(timeoutMs) {
                    case 0:
                        return
                    case -1:
                        throw EMProxyError.testConnectionFailed
                    case let err:
                        throw EMProxyError.unknownError(err)
                }
            }
        }
    }
}
